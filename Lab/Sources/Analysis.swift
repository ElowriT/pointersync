import Foundation
import CoreGraphics
import IOKit

struct DeviceTiming {
    var hz: Double
    var medianMs: Double
    var p10Ms: Double
    var p90Ms: Double
    var count: Int
    var latencyMedianMs: Double
    var latencyP99Ms: Double
    /// Reports that came at least half an interval late (a lost or delayed packet).
    var lateShare: Double
    /// Reports that came right after the previous one (a delayed packet catching up).
    var bunchedShare: Double
}

/// Name of the IORegistry service that sent pointer events (field 87).
enum ServiceInfo {
    struct Info { var name: String; var className: String; var builtIn: Bool }
    private static var cache: [Int64: Info?] = [:]

    static func lookup(_ id: Int64) -> Info? {
        if let cached = cache[id] { return cached }
        var info: Info? = nil
        if id > 0, let match = IORegistryEntryIDMatching(UInt64(id)) {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
            if service != 0 {
                func prop(_ k: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                var cls = [CChar](repeating: 0, count: 128)
                IOObjectGetClass(service, &cls)
                info = Info(name: prop("Product") as? String ?? "Устройство", className: String(cString: cls),
                            builtIn: prop("Built-In") as? Bool ?? false)
                IOObjectRelease(service)
            }
        }
        cache[id] = info
        return info
    }
}

/// How the cursor of one source moved frame by frame on one screen.
struct ScreenResult: Identifiable {
    var id: UInt32
    var name: String
    var refreshHz: Double
    var eventHz: Double
    var frames: Int
    /// Share of frames that got 0, 1, 2 or 3+ cursor updates.
    var hist: [Double]
    /// |step - local average step| / local average step, over moving frames.
    var unevenMedian: Double
    var unevenP95: Double
    var stallShare: Double
    var jumpShare: Double
    /// The same for a cursor resampled to vsync with a fixed delay.
    var smoothUnevenMedian: Double
    var smoothUnevenP95: Double
    var smoothStallShare: Double
    var addedLatencyMs: Double
    var tapLatencyMedianMs: Double
    var tapLatencyP99Ms: Double
    var updatedAt: Int64
}

struct SourceResult: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var smoothed = false
    var timing: DeviceTiming?
    var screens: [ScreenResult]
}

struct ScreenClock: Identifiable {
    var id: UInt32
    var name: String
    var nominalHz: Int
    var measuredHz: Double
}

struct Analysis {
    var sources: [SourceResult] = []
    var clocks: [ScreenClock] = []
}

enum Analyzer {
    /// A longer gap between samples means the hand stopped.
    static let pauseNs: Int64 = 40_000_000
    static let minFrames = 40
    /// Steps are compared with their average over ±4 frames.
    static let halfWindow = 4

    private struct Motion { var t: Int64; var r: Int64; var dx: Int32; var dy: Int32 }

    static func run(_ s: Snapshot, now: Int64) -> Analysis {
        var out = Analysis()
        let deviceByIndex = Dictionary(s.devices.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })

        var framesByDisplay: [UInt32: [Int64]] = [:]
        for f in s.frames { framesByDisplay[f.d, default: []].append(f.t) }
        for (k, v) in framesByDisplay { framesByDisplay[k] = Array(Set(v)).sorted() }
        for (id, info) in s.displays.sorted(by: { $0.key < $1.key }) {
            out.clocks.append(ScreenClock(id: id, name: info.name, nominalHz: info.maxFPS,
                                          measuredHz: rate(framesByDisplay[id] ?? [])))
        }

        // X and Y values with the same device and timestamp form one report.
        var motion: [Int32: [Motion]] = [:]
        var pending: [Int32: Motion] = [:]
        for v in s.values {
            let isX = v.u == 0x30
            if var p = pending[v.d], p.t == v.t {
                if isX { p.dx &+= v.v } else { p.dy &+= v.v }
                pending[v.d] = p
                continue
            }
            if let p = pending[v.d] { motion[v.d, default: []].append(p) }
            pending[v.d] = Motion(t: v.t, r: v.r, dx: isX ? v.v : 0, dy: isX ? 0 : v.v)
        }
        for (d, p) in pending { motion[d, default: []].append(p) }

        var reportsByDevice: [Int32: [HIDReport]] = [:]
        for r in s.reports { reportsByDevice[r.d, default: []].append(r) }

        // Device timing, and the timestamps used to tell which device made a pointer event.
        var timing: [Int32: DeviceTiming] = [:]
        var stamps: [(t: Int64, d: Int32)] = []
        for dev in s.devices {
            let moves = (motion[dev.index] ?? []).filter { $0.dx != 0 || $0.dy != 0 }
            let times: [(t: Int64, r: Int64)]
            if moves.count >= 10 {
                times = moves.map { ($0.t, $0.r) }
            } else if let reps = reportsByDevice[dev.index], reps.count >= 10 {
                times = reps.map { ($0.t, $0.r) }
            } else { continue }
            timing[dev.index] = deviceTiming(times)
            stamps += times.map { (t: $0.t, d: dev.index) }
        }
        stamps.sort { $0.t < $1.t }

        // Field 87 of a pointer event is the registry ID of the service that sent it; events
        // the smoother posted keep it, so they are told apart by their marker.
        struct SourceKey: Hashable, Comparable {
            var sender: Int64
            var smoothed: Bool
            static func < (a: SourceKey, b: SourceKey) -> Bool { (a.sender, a.smoothed ? 1 : 0) < (b.sender, b.smoothed ? 1 : 0) }
        }
        var eventsBySource: [SourceKey: [PointerEvent]] = [:]
        for e in s.events { eventsBySource[SourceKey(sender: e.f87, smoothed: e.m), default: []].append(e) }

        for (key, unsorted) in eventsBySource.sorted(by: { $0.key < $1.key }) {
            let sender = key.sender
            let events = unsorted.sorted { $0.t < $1.t }
            guard events.count >= 20 else { continue }
            // The raw HID device behind the sender: the one whose reports carry the same timestamps.
            var votes: [Int32: Int] = [:]
            for e in events { if let d = nearestDevice(stamps, e.t, tolerance: 300_000) { votes[d, default: 0] += 1 } }
            let linked = votes.max { $0.value < $1.value }.flatMap { $0.value * 2 >= events.count ? $0.key : nil }

            var title: String, subtitle: String, deviceTiming: DeviceTiming? = nil
            if let d = linked, let dev = deviceByIndex[d] {
                title = deviceTitle(dev)
                subtitle = transportName(dev)
                deviceTiming = timing[d]
            } else if let svc = ServiceInfo.lookup(sender) {
                let trackpad = (svc.name + svc.className).localizedCaseInsensitiveContains("trackpad")
                    || svc.className.contains("Multitouch")
                title = trackpad && svc.builtIn ? "Встроенный трекпад" : svc.name
                subtitle = trackpad ? "трекпад" : svc.className
            } else {
                title = "Курсор, источник не определён"
                subtitle = "отправитель \(sender)"
            }
            var screens: [ScreenResult] = []
            for (id, info) in s.displays.sorted(by: { $0.key < $1.key }) {
                let onScreen = events.filter { screen(of: $0, layouts: s.layouts) == id }
                guard onScreen.count >= 20, let frames = framesByDisplay[id],
                      var r = frameStats(frames: frames, events: onScreen),
                      r.frames >= minFrames else { continue }
                r.id = id
                r.name = info.name
                r.updatedAt = now
                screens.append(r)
            }
            if key.smoothed { subtitle = "после сглаживания" }
            if !screens.isEmpty {
                out.sources.append(SourceResult(id: "svc:\(sender)\(key.smoothed ? ":s" : "")", title: title,
                                                subtitle: subtitle, smoothed: key.smoothed,
                                                timing: deviceTiming, screens: screens))
            }
        }
        return out
    }

    // MARK: - Frame by frame

    private static func frameStats(frames all: [Int64], events e: [PointerEvent]) -> ScreenResult? {
        let frameStep = median(diffs(all))
        guard frameStep > 0 else { return nil }
        // Only frames while this source was producing events.
        let lo = lowerBound(all, e.first!.t), hi = lowerBound(all, e.last!.t + 1)
        guard hi - lo > 2 * halfWindow + 2 else { return nil }
        let f = Array(all[lo..<hi])
        let n = f.count

        // lastIdx[i]: last event at or before vsync i; updates[i]: events since vsync i-1.
        var lastIdx = [Int](repeating: -1, count: n)
        var updates = [Int](repeating: 0, count: n)
        var j = -1
        for i in 0..<n {
            var c = 0
            while j + 1 < e.count && e[j + 1].t <= f[i] { j += 1; c += 1 }
            lastIdx[i] = j
            updates[i] = c
        }
        func moving(_ i: Int) -> Bool {
            let li = lastIdx[i]
            return li >= 0 && li + 1 < e.count && f[i] - e[li].t <= pauseNs && e[li + 1].t - f[i] <= pauseNs
        }
        func contiguous(_ i: Int) -> Bool { f[i] - f[i - 1] <= frameStep * 3 / 2 }

        var steps = [Double](repeating: .nan, count: n)
        for i in 1..<n where moving(i) && moving(i - 1) && contiguous(i) {
            let a = e[lastIdx[i - 1]], b = e[lastIdx[i]]
            steps[i] = hypot(b.x - a.x, b.y - a.y)
        }

        // Resampled cursor: position interpolated at a fixed delay behind each vsync.
        let intervals = diffs(e.map { $0.t }).filter { $0 > 0 && $0 <= pauseNs }
        guard !intervals.isEmpty else { return nil }
        let delay = percentile(intervals.map(Double.init), 0.9) + 500_000
        var resampled = [CGPoint?](repeating: nil, count: n)
        var k = 0
        for i in 0..<n {
            let tau = f[i] - Int64(delay)
            while k + 1 < e.count && e[k + 1].t <= tau { k += 1 }
            guard e[k].t <= tau, k + 1 < e.count, e[k + 1].t - e[k].t <= pauseNs else { continue }
            let a = e[k], b = e[k + 1]
            let w = Double(tau - a.t) / Double(b.t - a.t)
            resampled[i] = CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w)
        }
        var smoothSteps = [Double](repeating: .nan, count: n)
        for i in 1..<n where contiguous(i) {
            if let a = resampled[i - 1], let b = resampled[i] { smoothSteps[i] = hypot(b.x - a.x, b.y - a.y) }
        }

        let raw = evenness(steps)
        let smooth = evenness(smoothSteps)
        guard !raw.frames.isEmpty else { return nil }

        var hist = [0.0, 0.0, 0.0, 0.0]
        var ageSum = 0.0
        for i in raw.frames {
            hist[min(updates[i], 3)] += 1
            ageSum += Double(f[i] - e[lastIdx[i]].t)
        }
        let count = Double(raw.frames.count)
        let tapLatency = e.map { Double($0.r - $0.t) }

        return ScreenResult(
            id: 0, name: "",
            refreshHz: 1e9 / Double(frameStep),
            eventHz: 1e9 / Double(median(intervals)),
            frames: raw.frames.count,
            hist: hist.map { $0 / count },
            unevenMedian: percentile(raw.errors, 0.5),
            unevenP95: percentile(raw.errors, 0.95),
            stallShare: Double(raw.stalls) / count,
            jumpShare: Double(raw.jumps) / count,
            smoothUnevenMedian: percentile(smooth.errors, 0.5),
            smoothUnevenP95: percentile(smooth.errors, 0.95),
            smoothStallShare: smooth.frames.isEmpty ? 0 : Double(smooth.stalls) / Double(smooth.frames.count),
            addedLatencyMs: (delay - ageSum / count) / 1e6,
            tapLatencyMedianMs: percentile(tapLatency, 0.5) / 1e6,
            tapLatencyP99Ms: percentile(tapLatency, 0.99) / 1e6,
            updatedAt: 0)
    }

    private struct Evenness { var frames: [Int] = []; var errors: [Double] = []; var stalls = 0; var jumps = 0 }

    private static func evenness(_ s: [Double]) -> Evenness {
        var r = Evenness()
        let h = halfWindow
        guard s.count > 2 * h + 1 else { return r }
        for i in h..<(s.count - h) {
            var sum = 0.0
            var complete = true
            for k in (i - h)...(i + h) {
                if s[k].isNaN { complete = false; break }
                sum += s[k]
            }
            guard complete else { continue }
            let mean = sum / Double(2 * h + 1)
            guard mean >= 0.5 else { continue }   // points per frame; slower is "standing"
            r.frames.append(i)
            r.errors.append(abs(s[i] - mean) / mean)
            if s[i] < 0.05 * mean { r.stalls += 1 }
            if s[i] > 1.5 * mean { r.jumps += 1 }
        }
        return r
    }

    // MARK: - Helpers

    /// Screen under the event, by the screen layout in effect when it arrived:
    /// opening the lid or plugging a monitor moves the others in global coordinates.
    private static func screen(of e: PointerEvent, layouts: [Layout]) -> UInt32? {
        guard let layout = layouts.last(where: { $0.t <= e.r }) ?? layouts.first else { return nil }
        return layout.displays.first { $0.bounds.contains(CGPoint(x: e.x, y: e.y)) }?.id
    }

    private static func deviceTiming(_ times: [(t: Int64, r: Int64)]) -> DeviceTiming {
        let sorted = times.sorted { $0.t < $1.t }
        let intervals = diffs(sorted.map { $0.t }).filter { $0 >= 0 && $0 <= pauseNs }.map { Double($0) }
        let latency = times.map { Double($0.r - $0.t) }
        let med = percentile(intervals, 0.5)
        let n = Double(max(intervals.count, 1))
        return DeviceTiming(hz: med > 0 ? 1e9 / med : 0,
                            medianMs: med / 1e6,
                            p10Ms: percentile(intervals, 0.1) / 1e6,
                            p90Ms: percentile(intervals, 0.9) / 1e6,
                            count: times.count,
                            latencyMedianMs: percentile(latency, 0.5) / 1e6,
                            latencyP99Ms: percentile(latency, 0.99) / 1e6,
                            lateShare: Double(intervals.filter { $0 > med * 1.5 }.count) / n,
                            bunchedShare: Double(intervals.filter { $0 < med * 0.4 }.count) / n)
    }

    private static func nearestDevice(_ stamps: [(t: Int64, d: Int32)], _ t: Int64, tolerance: Int64) -> Int32? {
        var lo = 0, hi = stamps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if stamps[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        var best: (Int64, Int32)? = nil
        for i in [lo - 1, lo] where i >= 0 && i < stamps.count {
            let d = abs(stamps[i].t - t)
            if d <= tolerance && (best == nil || d < best!.0) { best = (d, stamps[i].d) }
        }
        return best?.1
    }

    static func deviceTitle(_ d: DeviceInfo) -> String {
        if d.builtIn && (d.usagePage == 13 || d.name.contains("Trackpad")) { return "Встроенный трекпад" }
        return d.name
    }

    static func transportName(_ d: DeviceInfo) -> String {
        switch d.transport {
        case "Bluetooth Low Energy": return "Bluetooth LE"
        case "Bluetooth": return "Bluetooth"
        case "USB": return "USB"
        default: return d.builtIn ? "встроенное" : d.transport
        }
    }

    private static func rate(_ t: [Int64]) -> Double {
        let m = median(diffs(t))
        return m > 0 ? 1e9 / Double(m) : 0
    }

    private static func diffs(_ a: [Int64]) -> [Int64] {
        a.count < 2 ? [] : (1..<a.count).map { a[$0] - a[$0 - 1] }
    }

    private static func median(_ a: [Int64]) -> Int64 {
        a.isEmpty ? 0 : a.sorted()[a.count / 2]
    }

    private static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    private static func lowerBound(_ a: [Int64], _ t: Int64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
