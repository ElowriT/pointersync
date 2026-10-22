import Foundation
import CoreGraphics
import os

/// All timestamps are nanoseconds on the mach uptime clock (same base as
/// CACurrentMediaTime and IOHID timestamps).
enum Clock {
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    @inline(__always) static func ns(fromTicks t: UInt64) -> Int64 {
        Int64(t.multipliedReportingOverflow(by: timebase.numer).partialValue / timebase.denom)
    }

    @inline(__always) static func now() -> Int64 {
        ns(fromTicks: mach_absolute_time())
    }

    @inline(__always) static func ticks(fromNs ns: Int64) -> UInt64 {
        UInt64(max(ns, 0)) * timebase.denom / timebase.numer
    }

    private(set) static var eventTimestampsInTicks: Bool?

    /// CGEvent timestamps are mach ticks for events from devices but nanoseconds for events
    /// made with the CGEvent initializers. The two are ~40x apart: whichever clock the
    /// value is closer to now is its unit.
    private static func inTicks(_ raw: UInt64, now ticks: UInt64) -> Bool {
        abs(Int64(bitPattern: raw) &- Int64(ticks)) < abs(Int64(bitPattern: raw) &- ns(fromTicks: ticks))
    }

    static func eventTime(_ raw: UInt64) -> Int64 {
        let ticks = inTicks(raw, now: mach_absolute_time())
        eventTimestampsInTicks = ticks
        return ticks ? ns(fromTicks: raw) : Int64(bitPattern: raw)
    }

    /// The current time in the same unit as the event timestamp `raw`.
    static func eventStamp(like raw: UInt64) -> UInt64 {
        let ticks = mach_absolute_time()
        return inTicks(raw, now: ticks) ? ticks : UInt64(ns(fromTicks: ticks))
    }
}

struct DeviceInfo: Codable {
    var index: Int32
    var name: String
    var transport: String
    var vendorID: Int
    var productID: Int
    var usagePage: Int
    var usage: Int
    var registryID: UInt64
    var builtIn: Bool
    var maxInputReportSize: Int
}

struct DisplayInfo: Codable {
    var id: UInt32
    var name: String
    var maxFPS: Int
    var modeRefresh: Double
    var bounds: CGRect
    var builtIn: Bool
}

/// The screens and their places in global coordinates, from time t on.
struct Layout: Codable { var t: Int64; var displays: [DisplayInfo] }

/// One raw input report from a HID device (any report, including multitouch frames).
struct HIDReport: Codable { var d: Int32; var t: Int64; var r: Int64; var len: Int32 }
/// One relative X/Y value from a HID device. Values sharing (d, t) belong to one report.
struct HIDValue: Codable { var d: Int32; var t: Int64; var r: Int64; var u: UInt32; var v: Int32 }
/// One pointer event as seen by the HID-level event tap. x/y is the new cursor location.
struct PointerEvent: Codable {
    var t: Int64; var r: Int64
    var x: Double; var y: Double
    var dx: Double; var dy: Double
    var type: UInt32; var sub: Int64; var f87: Int64
    /// Posted by the smoother rather than coming from the device.
    var m: Bool = false
}
/// One display refresh: t is the vsync time of the frame, target the next one.
struct Frame: Codable { var d: UInt32; var t: Int64; var target: Int64; var r: Int64 }
/// Non-zero integer fields of an early event, to find which field names the source device.
struct ProbeSample: Codable { var t: Int64; var sub: Int64; var fields: [String: Int64] }
/// WindowServer's own pointer position from a device motion event, as the smoother saw it;
/// held: the smoother kept the event from moving the cursor.
struct PointerSample: Codable { var t: Int64; var r: Int64; var x: Double; var y: Double; var held: Bool }
/// The cursor's on-screen scale when it changed ("shake to locate" enlarges it).
struct ScaleSample: Codable { var r: Int64; var s: Double }

struct Status: Codable {
    var hidAccess: Int = -1          // IOHIDAccessType: 0 granted, 1 denied, 2 unknown
    var hidOpen: Int32? = nil        // IOReturn of IOHIDManagerOpen
    var tapRunning: Bool? = nil
    var listenAccess: Bool = false
    var eventTimestampsInTicks: Bool? = nil
}

struct Snapshot {
    var devices: [DeviceInfo] = []
    var displays: [UInt32: DisplayInfo] = [:]
    var layouts: [Layout] = []
    var reports: [HIDReport] = []
    var values: [HIDValue] = []
    var events: [PointerEvent] = []
    var frames: [Frame] = []
    var probes: [ProbeSample] = []
    var pointer: [PointerSample] = []
    var scales: [ScaleSample] = []
    var status = Status()
}

final class Recorder {
    static let shared = Recorder()

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    func addDevice(_ d: DeviceInfo) { state.withLock { $0.devices.append(d) } }
    func setDisplays(_ list: [DisplayInfo]) {
        let t = Clock.now()
        state.withLock { s in
            for d in list { s.displays[d.id] = d }
            s.layouts.append(Layout(t: t, displays: list))
        }
    }
    func add(_ r: HIDReport) { state.withLock { $0.reports.append(r) } }
    func add(_ v: HIDValue) { state.withLock { $0.values.append(v) } }
    func add(_ e: PointerEvent) { state.withLock { $0.events.append(e) } }
    func add(_ f: Frame) { state.withLock { $0.frames.append(f) } }
    func add(_ p: PointerSample) { state.withLock { $0.pointer.append(p) } }
    func add(_ c: ScaleSample) { state.withLock { $0.scales.append(c) } }

    func addProbe(_ p: ProbeSample) -> Bool {
        state.withLock { s in
            guard s.probes.count < 80 else { return false }
            s.probes.append(p)
            return true
        }
    }
    func updateStatus(_ f: (inout Status) -> Void) { state.withLock { f(&$0.status) } }

    /// Copies everything received since `since` (by arrival time).
    func snapshot(since: Int64) -> Snapshot {
        state.withLock { s in
            var out = Snapshot()
            out.devices = s.devices
            out.displays = s.displays
            out.layouts = s.layouts
            out.probes = s.probes
            out.pointer = Array(s.pointer[Self.firstIndex(s.pointer, since) { $0.r }...])
            out.scales = Array(s.scales[Self.firstIndex(s.scales, since) { $0.r }...])
            out.status = s.status
            out.reports = Array(s.reports[Self.firstIndex(s.reports, since) { $0.r }...])
            out.values = Array(s.values[Self.firstIndex(s.values, since) { $0.r }...])
            out.events = Array(s.events[Self.firstIndex(s.events, since) { $0.r }...])
            out.frames = Array(s.frames[Self.firstIndex(s.frames, since) { $0.r }...])
            return out
        }
    }

    func trim(before cutoff: Int64) {
        state.withLock { s in
            s.reports.removeFirst(Self.firstIndex(s.reports, cutoff) { $0.r })
            s.values.removeFirst(Self.firstIndex(s.values, cutoff) { $0.r })
            s.events.removeFirst(Self.firstIndex(s.events, cutoff) { $0.r })
            s.frames.removeFirst(Self.firstIndex(s.frames, cutoff) { $0.r })
            s.pointer.removeFirst(Self.firstIndex(s.pointer, cutoff) { $0.r })
            s.scales.removeFirst(Self.firstIndex(s.scales, cutoff) { $0.r })
        }
    }

    func clear() {
        state.withLock { s in
            s.reports.removeAll(); s.values.removeAll(); s.events.removeAll(); s.frames.removeAll()
            s.pointer.removeAll(); s.scales.removeAll()
        }
    }

    /// Arrays are appended in arrival order, so arrival time is sorted.
    private static func firstIndex<T>(_ a: [T], _ t: Int64, _ key: (T) -> Int64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(a[mid]) < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
