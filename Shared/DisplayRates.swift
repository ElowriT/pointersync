import AppKit
import CoreGraphics

// WindowServer's own display mode list (private; these return nothing).
@_silgen_name("CGSGetCurrentDisplayMode")
private func CGSGetCurrentDisplayMode(_ display: UInt32, _ mode: UnsafeMutablePointer<Int32>)
@_silgen_name("CGSGetNumberOfDisplayModes")
private func CGSGetNumberOfDisplayModes(_ display: UInt32, _ count: UnsafeMutablePointer<Int32>)
@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
private func CGSGetDisplayModeDescriptionOfLength(_ display: UInt32, _ index: Int32, _ mode: UnsafeMutableRawPointer, _ length: Int32)
@_silgen_name("CGSConfigureDisplayMode")
private func CGSConfigureDisplayMode(_ config: CGDisplayConfigRef, _ display: UInt32, _ mode: Int32)

/// How well one refresh rate suits a pointing device's report timing.
struct RateOption: Identifiable {
    var hz: Double
    var id: Double { hz }
    /// Mean |time the cursor advances in a frame - frame interval| / frame interval.
    var uneven: Double
    /// Frames without a new report (the cursor stands still) and with two or more (it jumps).
    var empty: Double
    var doubles: Double
    var current: Bool
    /// Frames where the cursor stood still or jumped two steps.
    var hitches: Double { empty + doubles }
    var score: Double { uneven }
}

/// Refresh rates a screen offers, how well each suits a device's report times, and switching.
///
/// Without smoothing macOS shows each report as soon as it comes. A frame then shows the
/// newest report, and the cursor moves evenly only if every frame advances it by the same
/// time. That depends on how the report rate and the refresh rate line up, so each rate the
/// screen offers is replayed against the device's recorded reports.
enum DisplayRates {
    /// A longer gap between reports means the hand stopped.
    static let pause: Int64 = 40_000_000

    /// Runs of steady motion, at least 10 reports each.
    static func split(_ times: [Int64]) -> [[Int64]] {
        var runs: [[Int64]] = []
        var run: [Int64] = []
        for t in times {
            if let last = run.last, t - last > pause {
                if run.count >= 10 { runs.append(run) }
                run = []
            }
            run.append(t)
        }
        if run.count >= 10 { runs.append(run) }
        return runs
    }

    /// Replays the reports against frames at `hz`, at a few phases, as macOS shows them.
    static func evaluate(_ runs: [[Int64]], hz: Double) -> (uneven: Double, empty: Double, doubles: Double) {
        let p = 1e9 / hz
        var deviation = 0.0
        var frames = 0, empty = 0, doubles = 0
        for phase in [0.0, 0.25, 0.5, 0.75] {
            for r in runs {
                var j = -1
                var previous: Int64?
                var v = Double(r[0]) + phase * p
                while v <= Double(r[r.count - 1]) {
                    var count = 0
                    while j + 1 < r.count && Double(r[j + 1]) <= v { j += 1; count += 1 }
                    let newest = j >= 0 ? r[j] : nil
                    if let a = previous, let b = newest, j < r.count - 1 {
                        frames += 1
                        deviation += abs(Double(b - a) - p) / p
                        if count == 0 { empty += 1 }
                        if count >= 2 { doubles += 1 }
                    }
                    previous = newest
                    v += p
                }
            }
        }
        guard frames > 0 else { return (.nan, .nan, .nan) }
        let n = Double(frames)
        return (deviation / n, Double(empty) / n, Double(doubles) / n)
    }

    /// Refresh rates the screen offers at its current resolution and scale. The public mode
    /// list has HiDPI modes only at the current rate (BetterDisplay-style HiDPI included), so
    /// the full list comes from WindowServer's own one, which System Settings uses too.
    static func modes(for id: UInt32) -> [(hz: Double, number: Int32)] {
        guard let current = currentMode(id), let now = describe(id, current) else { return [] }
        var count: Int32 = 0
        CGSGetNumberOfDisplayModes(id, &count)
        var byRate: [Double: Int32] = [:]
        for i in 0..<count {
            guard let m = describe(id, i), m.width == now.width, m.height == now.height,
                  m.density == now.density, m.hz > 0 else { continue }
            if byRate[m.hz] == nil || i == current { byRate[m.hz] = i }
        }
        return byRate.sorted { $0.key < $1.key }.map { (hz: $0.key, number: $0.value) }
    }

    static func currentMode(_ id: UInt32) -> Int32? {
        var current: Int32 = -1
        CGSGetCurrentDisplayMode(id, &current)
        return current >= 0 ? current : nil
    }

    /// Switches the screen to `hz` at its current resolution and scale. Only on the user's click.
    static func switchTo(_ id: UInt32, hz: Double) -> Bool {
        guard let number = modes(for: id).first(where: { abs($0.hz - hz) < 0.01 })?.number else { return false }
        return switchTo(id, mode: number)
    }

    /// Switches the screen to one entry of WindowServer's mode list, and keeps it.
    static func switchTo(_ id: UInt32, mode: Int32) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGSConfigureDisplayMode(config, id, mode)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    private struct Mode { var width: UInt32; var height: UInt32; var hz: Double; var density: Float }

    /// Layout of WindowServer's mode description (as used by displayplacer).
    private static func describe(_ id: UInt32, _ index: Int32) -> Mode? {
        var raw = [UInt8](repeating: 0, count: 0xDC)
        raw.withUnsafeMutableBytes { CGSGetDisplayModeDescriptionOfLength(id, index, $0.baseAddress!, 0xD4) }
        let m = raw.withUnsafeBytes { b in
            Mode(width: b.load(fromByteOffset: 0x08, as: UInt32.self),
                 height: b.load(fromByteOffset: 0x0C, as: UInt32.self),
                 hz: Double(b.load(fromByteOffset: 0xBE, as: UInt16.self)),
                 density: b.load(fromByteOffset: 0xD0, as: Float.self))
        }
        return m.width > 0 && m.height > 0 ? m : nil
    }
}
