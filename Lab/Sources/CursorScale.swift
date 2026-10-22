import Foundation
import CoreGraphics

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetCursorScale")
private func CGSGetCursorScale(_ connection: Int32, _ scale: UnsafeMutablePointer<Float>) -> Int32

/// Watches the cursor's scale, so every "shake to locate" enlargement is on record.
enum CursorScale {
    static func start() {
        let thread = Thread {
            let connection = CGSMainConnectionID()
            var last: Float = -1
            while true {
                var scale: Float = 0
                if CGSGetCursorScale(connection, &scale) == 0, abs(scale - last) > 0.01 {
                    last = scale
                    Recorder.shared.add(ScaleSample(r: Clock.now(), s: Double(scale)))
                }
                usleep(10_000)
            }
        }
        thread.name = "pointersync.cursorscale"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Enlargements (scale above 1.2× the resting one) in a stretch of samples.
    static func enlargements(_ samples: [ScaleSample]) -> [Int64] {
        guard let rest = samples.map(\.s).min() else { return [] }
        var onsets: [Int64] = []
        var up = false
        for c in samples {
            if !up && c.s > rest * 1.2 { onsets.append(c.r); up = true }
            if up && c.s <= rest * 1.05 { up = false }
        }
        return onsets
    }
}
