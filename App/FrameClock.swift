import AppKit
import QuartzCore

/// Ticks once per frame of the window's screen, at the screen's full rate, for anything
/// that moves. (SwiftUI's own animation timeline tops out near 120 a second.)
@MainActor
final class FrameClock: NSObject, ObservableObject {
    static let shared = FrameClock()

    /// The time the next frame shows up, in CACurrentMediaTime seconds.
    @Published private(set) var now: CFTimeInterval = CACurrentMediaTime()
    var onFrame: (() -> Void)?
    private var link: CADisplayLink?

    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        // The screen's fastest mode, so a later switch to a faster rate isn't capped.
        let screen = view.window?.screen
        let top = screen.flatMap(SetupModel.displayID).flatMap { DisplayRates.modes(for: $0).map(\.hz).max() }
        let fps = Float(max(top ?? 0, Double(screen?.maximumFramesPerSecond ?? 120)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        now = link.targetTimestamp
        onFrame?()
    }
}

/// Where the cursor is at every frame of one screen, sampled on its own thread so the
/// app's own drawing never delays a sample.
final class FrameSampler: NSObject {
    struct Sample { var t: Double; var p: CGPoint }

    private let lock = NSLock()
    private var buffer: [Sample] = []
    /// The link samples are taken from; an old one still winding down is ignored.
    private var link: CADisplayLink?
    private var thread: Thread?

    /// Starts on the screen's frames at `hz`, the rate it was just switched to, replacing any
    /// earlier link (a mode switch changes the frames).
    @MainActor
    func start(screen: NSScreen, hz: Double) {
        stop()
        nonisolated(unsafe) let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        // Never below the screen's rate (its own figure can lag behind a switch), or the link
        // would skip every other frame.
        let fps = Float(max(hz, Double(screen.maximumFramesPerSecond))) + 3
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fps, preferred: fps)
        let thread = Thread {
            link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
            link.invalidate()
        }
        thread.name = "pointersync.sampler"
        thread.qualityOfService = .userInteractive
        lock.lock()
        self.link = link
        buffer = []
        lock.unlock()
        self.thread = thread
        thread.start()
    }

    func stop() {
        thread?.cancel()
        thread = nil
        lock.lock()
        link = nil
        lock.unlock()
    }

    /// Everything sampled since the last call.
    func take() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        let samples = buffer
        buffer = []
        return samples
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let p = CGEvent(source: nil)?.location else { return }
        lock.lock()
        if link === self.link { buffer.append(Sample(t: link.timestamp, p: p)) }
        lock.unlock()
    }
}

/// Where the real cursor has been, read once a frame, for the dial: its last positions
/// (global, y down), a centre that follows the hand slowly, how far the hand reaches from it,
/// which way from it the cursor is now, and how lately it passed each direction round.
@MainActor
final class CursorTrail {
    static let shared = CursorTrail()
    static let slots = 72

    private(set) var points: [CGPoint] = []
    private(set) var center = CGPoint.zero
    private(set) var reach = 150.0
    /// From the centre, radians, y down: 0 is three o'clock, −π/2 twelve.
    private(set) var angle = -Double.pi / 2
    private(set) var glow = [Double](repeating: 0, count: slots)
    private var frozen = false
    private var aimed = false
    private var last = 0.0

    func step(now: Double) {
        guard !frozen, let p = CGEvent(source: nil)?.location else { return }
        let dt = last == 0 ? 0 : min(now - last, 0.1)
        last = now
        if points.isEmpty { center = p }
        points.append(p)
        if points.count > 36 { points.removeFirst(points.count - 36) }
        let k = 1 - exp(-dt / 0.7)
        center = CGPoint(x: center.x + (p.x - center.x) * k, y: center.y + (p.y - center.y) * k)
        let d = Double(hypot(p.x - center.x, p.y - center.y))
        // Grows at once with bigger moves, shrinks slowly after.
        reach += (max(d, 120) - reach) * (1 - exp(-dt / (d > reach ? 0.25 : 2)))
        let fade = exp(-dt / 0.8)
        for i in glow.indices { glow[i] *= fade }
        guard d > 6 else { return }
        let a = atan2(Double(p.y - center.y), Double(p.x - center.x))
        if !aimed { angle = a; aimed = true }
        // Light every direction passed since the last frame, the short way round.
        let delta = (a - angle).remainder(dividingBy: 2 * .pi)
        let steps = Int(abs(delta) / (2 * .pi) * Double(Self.slots)) + 1
        for s in 0...steps { glow[slot(angle + delta * Double(s) / Double(steps))] = 1 }
        angle = a
    }

    /// The slot round the dial for a direction, from twelve o'clock clockwise.
    func slot(_ a: Double) -> Int {
        var turns = ((a + .pi / 2) / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        if turns < 0 { turns += 1 }
        return Int(turns * Double(Self.slots) + 0.5) % Self.slots
    }

    /// A made-up hand circling clockwise once a second, `turn` of the way round from twelve,
    /// for `--preview`; the real cursor is left alone from then on.
    func preview(radius: Double, turn: Double) {
        frozen = true
        center = .zero
        reach = radius
        points = (0..<36).map { k in
            let a = 2 * .pi * (turn - Double(35 - k) / 144) - .pi / 2
            return CGPoint(x: radius * cos(a), y: radius * sin(a))
        }
        angle = 2 * .pi * turn - .pi / 2
        for i in glow.indices {
            let behind = (turn - Double(i) / Double(Self.slots) + 1).truncatingRemainder(dividingBy: 1)
            glow[i] = exp(-behind / 0.12)
        }
    }
}
