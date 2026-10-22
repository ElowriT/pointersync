import AppKit
import CoreGraphics

struct RateScreen: Identifiable {
    var id: UInt32
    var name: String
    var currentHz: Double
    var options: [RateOption]
    var best: Double?
}

struct RateSource: Identifiable {
    var id: String
    var name: String
    var detail: String
    var reports: Int
    var lastActive: Int64
    var screens: [RateScreen]
}

/// Picks the refresh rate that best matches a pointing device, from its real report times.
///
/// Without smoothing macOS shows each report as soon as it comes. A frame then shows the
/// newest report, and the cursor moves evenly only if every frame advances it by the same
/// time. That depends on how the report rate and the refresh rate line up, so each rate the
/// screen offers is replayed against the device's recorded reports.
enum RateMatcher {
    /// Below this the screen has too few frames for everything else, whatever the cursor does.
    static let minimumHz = 90.0
    static let window: Int64 = 120_000_000_000

    static func advise(_ s: Snapshot, now: Int64) -> [RateSource] {
        var sources: [RateSource] = []

        // Mice: report times straight from HID, which smoothing does not touch.
        var moving: [Int32: Set<Int64>] = [:]
        for v in s.values where v.v != 0 { moving[v.d, default: []].insert(v.t) }
        for dev in s.devices {
            guard let set = moving[dev.index], set.count >= 200 else { continue }
            let times = set.sorted()
            sources.append(source(id: "hid:\(dev.index)", name: Analyzer.deviceTitle(dev),
                                  transport: Analyzer.transportName(dev), times: times, now: now))
        }
        // Trackpad: its reports are not readable, but its pointer events are.
        let trackpad = s.events.filter { $0.sub == 3 && !$0.m }.map { $0.t }.sorted()
        if trackpad.count >= 200 {
            sources.append(source(id: "trackpad", name: "Трекпад", transport: "", times: trackpad, now: now))
        }
        return sources.filter { !$0.screens.isEmpty }.sorted { $0.lastActive > $1.lastActive }
    }

    private static func source(id: String, name: String, transport: String, times: [Int64], now: Int64) -> RateSource {
        let runs = DisplayRates.split(times)
        let intervals = runs.flatMap { r in (1..<r.count).map { Double(r[$0] - r[$0 - 1]) } }.sorted()
        let median = intervals.isEmpty ? 0 : intervals[intervals.count / 2]
        let late = intervals.isEmpty ? 0 : Double(intervals.filter { $0 > median * 1.5 }.count) / Double(intervals.count)
        var detail = median > 0 ? "отчёт каждые \(f1(median / 1e6)) мс (\(f0(1e9 / median)) Гц)" : ""
        if late >= 0.02 { detail += ", опоздавших \(pct(late))" }
        if !transport.isEmpty { detail = transport + " · " + detail }

        var screens: [RateScreen] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let current = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
            let options = DisplayRates.modes(for: id).map(\.hz).filter { $0 >= minimumHz }.map { hz -> RateOption in
                let r = DisplayRates.evaluate(runs, hz: hz)
                return RateOption(hz: hz, uneven: r.uneven, empty: r.empty, doubles: r.doubles,
                                  current: abs(hz - current) < 0.5)
            }
            guard !options.isEmpty, options.contains(where: { $0.uneven.isFinite }) else { continue }
            let best = options.filter { $0.uneven.isFinite }.min { $0.score < $1.score }?.hz
            screens.append(RateScreen(id: id, name: screen.localizedName, currentHz: current,
                                      options: options.sorted { $0.hz > $1.hz }, best: best))
        }
        return RateSource(id: id, name: name, detail: detail, reports: times.count,
                          lastActive: times.last ?? 0, screens: screens)
    }

    /// Switches the screen to `hz` at its current resolution and scale. Only on the user's click.
    static func switchTo(_ id: UInt32, hz: Double) -> Bool { DisplayRates.switchTo(id, hz: hz) }
}
