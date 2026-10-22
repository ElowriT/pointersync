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
/// (global, y down), and two ways to show them. During the test, an orbit: a centre that
/// follows the hand slowly and a scale that fits its reach, so circles stay round the middle;
/// `angle` is the cursor's direction from that centre. On the start screen, a canvas: a window
/// onto the screen around the hand that slides after the cursor, so a drawing keeps its shape
/// and only drifts as a whole: gently while the hand moves near the middle, quicker further
/// out and once the hand rests. Towards the edge the cursor eases off and never quite gets
/// there. `canvasAngle` is the cursor's direction there, and `glow` how lately it passed each
/// one.
@MainActor
final class CursorTrail {
    static let shared = CursorTrail()
    static let slots = 72
    /// Screen points to dial points on the canvas: a drawing 400 points wide fills most of it.
    static let canvasScale: CGFloat = 0.22
    static let canvasRadius = Dial.cursorRadius(for: 250)

    private(set) var points: [CGPoint] = []
    private(set) var center = CGPoint.zero
    private(set) var reach = 150.0
    /// From the centre, radians, y down: 0 is three o'clock, −π/2 twelve.
    private(set) var angle = -Double.pi / 2
    private(set) var canvasCenter: CGPoint?
    private(set) var canvasAngle = -Double.pi / 2
    private(set) var glow = [Double](repeating: 0, count: slots)
    private var frozen = false
    private var aimed = false
    private var last = 0.0
    private var lastMove = 0.0

    func step(now: Double) {
        guard !frozen, let p = CGEvent(source: nil)?.location else { return }
        let dt = last == 0 ? 0 : min(now - last, 0.1)
        last = now
        if points.isEmpty { center = p }
        if let q = points.last, hypot(p.x - q.x, p.y - q.y) > 0.25 { lastMove = now }
        points.append(p)
        if points.count > 300 { points.removeFirst(points.count - 300) }
        // The orbit.
        let k = 1 - exp(-dt / 0.7)
        center = CGPoint(x: center.x + (p.x - center.x) * k, y: center.y + (p.y - center.y) * k)
        let d = Double(hypot(p.x - center.x, p.y - center.y))
        // Grows at once with bigger moves, shrinks slowly after.
        reach += (max(d, 120) - reach) * (1 - exp(-dt / (d > reach ? 0.25 : 2)))
        if d > 6 { angle = atan2(Double(p.y - center.y), Double(p.x - center.x)) }
        // The canvas: drifting to centre the cursor, slowly while the hand moves near the middle,
        // quicker the further out it gets and after a fifth of a second at rest; pushed along
        // only when the cursor is twice as far out as the edge.
        var c = canvasCenter ?? p
        let r = Self.canvasRadius, scale = Self.canvasScale
        let off = hypot(p.x - c.x, p.y - c.y) * scale
        if off > 2 * r {
            let keep = 2 * r / off
            c = CGPoint(x: p.x - (p.x - c.x) * keep, y: p.y - (p.y - c.y) * keep)
        }
        let out = Double(min(off, 2 * r) / r)
        let pull = 1 - exp(-dt / (now - lastMove > 0.2 ? 0.5 : 1.5 / (1 + 2 * out * out)))
        c = CGPoint(x: c.x + (p.x - c.x) * pull, y: c.y + (p.y - c.y) * pull)
        canvasCenter = c
        let fade = exp(-dt / 0.8)
        for i in glow.indices { glow[i] *= fade }
        guard hypot(p.x - c.x, p.y - c.y) * scale > 4 else { return }
        let a = atan2(Double(p.y - c.y), Double(p.x - c.x))
        if !aimed { canvasAngle = a; aimed = true }
        // Light every direction passed since the last frame, the short way round.
        let delta = (a - canvasAngle).remainder(dividingBy: 2 * .pi)
        let steps = Int(abs(delta) / (2 * .pi) * Double(Self.slots)) + 1
        for s in 0...steps { glow[slot(canvasAngle + delta * Double(s) / Double(steps))] = 1 }
        canvasAngle = a
    }

    /// Where the start screen's dial shows a position: on the canvas, from the dial's middle,
    /// in dial points. True to scale round the middle, then easing off towards the edge, which
    /// it never quite reaches.
    func canvas(_ p: CGPoint) -> CGPoint {
        let c = canvasCenter ?? p
        let dx = (p.x - c.x) * Self.canvasScale, dy = (p.y - c.y) * Self.canvasScale
        let d = hypot(dx, dy), r = Self.canvasRadius
        let even = 0.55 * r, edge = 0.92 * r
        guard d > even else { return CGPoint(x: dx, y: dy) }
        let shown = even + (edge - even) * CGFloat(tanh(Double((d - even) / (edge - even))))
        return CGPoint(x: dx * shown / d, y: dy * shown / d)
    }

    /// Where the test's dial shows a position: on the orbit, from the dial's middle, scaled so
    /// the hand's usual reach fills `radius`, and no further out than that.
    func place(_ p: CGPoint, radius: CGFloat) -> CGPoint {
        let scale = CGFloat(min(0.3, Double(radius) / reach))
        var dx = (p.x - center.x) * scale, dy = (p.y - center.y) * scale
        let d = hypot(dx, dy)
        if d > radius {
            dx *= radius / d
            dy *= radius / d
        }
        return CGPoint(x: dx, y: dy)
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
        canvasCenter = .zero
        canvasAngle = angle
        for i in glow.indices {
            let behind = (turn - Double(i) / Double(Self.slots) + 1).truncatingRemainder(dividingBy: 1)
            glow[i] = exp(-behind / 0.12)
        }
    }
}
