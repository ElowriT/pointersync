import AppKit

/// One frame of the rate being recorded: the cursor's step in it against the steps around it
/// (nil: too slow to count), and where the cursor was.
struct LiveFrame {
    var r: Double?
    var p: CGPoint
}

/// One refresh rate, tried for real: the screen ran at it while the hand kept circling.
struct RateTrial: Identifiable {
    var hz: Double
    var mode: Int32
    var id: Double { hz }
    /// Frames of brisk motion measured.
    var frames = 0
    /// Summed over those frames: how far each frame's step is from the steps around it.
    var off = 0.0
    /// Frames where the cursor stood still: at a rate above the mouse's, the frames it skips.
    var stallCount = 0
    /// The unevenness of every run of 30 frames, to tell how sure the average is.
    var blocks: [Double] = []
    /// A stretch of per-frame steps, each relative to the steps around it, for the strip.
    var strip: [Double] = []
    /// What each try at this rate looked like, for the saved measurement: whether the frames
    /// came at this rate before recording, the median frame interval while recording (ms),
    /// how long the recording took (s), and the frames it got.
    var attempts: [[String: Double]] = []

    /// How far, on average, a frame's step is from the steps around it (0 = a perfectly even comb).
    var uneven: Double { frames > 0 ? off / Double(frames) : 0 }
    var stalls: Double { frames > 0 ? Double(stallCount) / Double(frames) : 0 }
    var smooth: Double { max(0, 1 - uneven) }
    var measured: Bool { frames >= 60 }

    /// The likely error of `uneven`: how much the runs of frames differ, over how many there are.
    var spread: Double {
        guard blocks.count >= 2 else { return 1 }
        let mean = blocks.reduce(0, +) / Double(blocks.count)
        let variance = blocks.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(blocks.count - 1)
        return (variance / Double(blocks.count)).squareRoot()
    }

    mutating func add(_ s: RateTester.Score) {
        frames += s.frames
        off += s.off
        stallCount += s.stalls
        blocks += s.blocks
        if s.strip.count >= strip.count { strip = s.strip }
    }
}

/// Switches a screen through its refresh rates and measures, at each, how evenly the cursor
/// moves from frame to frame while the hand circles.
///
/// Apps can no longer see when a mouse reports: macOS hands them its events already lined
/// up with the frames. But where the cursor is at each frame can be read, with no
/// permission, and that is what the screen shows. During brisk motion each frame's step is
/// compared with the steps around it: a skipped frame, a double step, or steps of 0.75 and
/// 1.5 in turn all count, by how far they are off.
///
/// Every rate is tried once, from the current one down. If the best two are then too close
/// to tell apart, both are tried again in reverse order, so a hand that tires or speeds up
/// along the way weighs on both alike.
@MainActor
final class RateTester {
    enum Phase: Equatable { case idle, settling, recording, finished }

    private(set) var trials: [RateTrial] = []
    /// The order trials run in, as indices into `trials`.
    private(set) var plan: [Int] = []
    private(set) var position = 0
    private(set) var phase = Phase.idle
    private(set) var display: UInt32 = 0
    private(set) var originalMode: Int32?
    private(set) var originalHz = 0.0
    /// The two rates tried again, once the first round couldn't tell them apart.
    private(set) var recheck: [Double] = []
    /// The hand's velocity over the last few frames, points per second.
    private(set) var velocity = CGVector.zero
    private(set) var briskSoFar = 0.0
    private(set) var lastMotion = 0.0
    /// The latest frames at the rate being recorded, at `liveHz`, for the live picture.
    private(set) var live: [LiveFrame] = []
    private(set) var liveHz = 0.0

    /// Slower hands report less often than the mouse can, and say nothing about the screen.
    static let briskSpeed = 400.0
    static let briskSeconds = 3.0
    static let settleSeconds = 0.8
    static let giveUpSeconds = 15.0

    private let sampler = FrameSampler()
    private var samples: [FrameSampler.Sample] = []
    private var phaseStart = 0.0
    private var frameCount = 0
    private var liveNext = 0
    private var settledAtRate = false

    /// The first round fills four fifths of the way, a second look at two rates the rest.
    var progress: Double {
        guard !trials.isEmpty else { return 0 }
        if phase == .finished { return 1 }
        let within = phase == .recording ? min(1, briskSoFar / Self.briskSeconds) : 0
        let done = Double(position) + within
        let first = Double(trials.count)
        if done < first { return 0.8 * done / first }
        return 0.8 + 0.2 * (done - first) / Double(max(plan.count - trials.count, 1))
    }

    var current: RateTrial? { position < plan.count ? trials[plan[position]] : nil }

    func begin(on screen: NSScreen) {
        guard let id = SetupModel.displayID(screen) else { return }
        display = id
        originalMode = DisplayRates.currentMode(id)
        originalHz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        let modes = DisplayRates.modes(for: id)
        let top = modes.map(\.hz).max() ?? 0
        // From 90 Hz up (fewer frames are no good for anything else), at most five rates.
        var list = Array(modes.filter { $0.hz >= min(90, top) }.sorted { $0.hz > $1.hz }.prefix(5))
        // The current rate first: it needs no switch.
        if let i = list.firstIndex(where: { abs($0.hz - originalHz) < 0.5 }) { list.insert(list.remove(at: i), at: 0) }
        trials = list.map { RateTrial(hz: $0.hz, mode: $0.number) }
        plan = Array(trials.indices)
        position = 0
        recheck = []
        lastMotion = 0
        live = []
        guard !trials.isEmpty else { phase = .finished; return }
        startTrial()
    }

    /// Stops a test under way, and puts the screen back to the rate it had.
    func abort() {
        sampler.stop()
        guard phase == .settling || phase == .recording else { return }
        restore()
        phase = .idle
    }

    private func startTrial() {
        let trial = trials[plan[position]]
        if DisplayRates.currentMode(display) != trial.mode { _ = DisplayRates.switchTo(display, mode: trial.mode) }
        // A new mode brings new frames: listen to them afresh.
        if let screen = NSScreen.screens.first(where: { SetupModel.displayID($0) == display }) { sampler.start(screen: screen, hz: trial.hz) }
        samples = []
        briskSoFar = 0
        settledAtRate = false
        phase = .settling
        phaseStart = CACurrentMediaTime()
    }

    /// Called every frame on the main thread.
    func step() {
        guard phase == .settling || phase == .recording else { return }
        let fresh = sampler.take()
        track(fresh)
        let now = CACurrentMediaTime()
        let trial = trials[plan[position]]
        samples.append(contentsOf: fresh)
        if phase == .settling {
            if samples.count > 16 { samples.removeFirst(samples.count - 16) }
            // Frames come at the new rate and the screen has had a moment to settle.
            let gaps = zip(samples.dropFirst(), samples).map { $0.t - $1.t }.sorted()
            let atRate = gaps.count >= 10 && abs(gaps[gaps.count / 2] * trial.hz - 1) < 0.08
            if (atRate && now - phaseStart > Self.settleSeconds) || now - phaseStart > 5 {
                settledAtRate = atRate
                samples = []
                phase = .recording
                phaseStart = now
                live = []
                liveHz = trial.hz
                liveNext = 5   // the first frame with four before it
            }
            return
        }
        // Each frame's step needs the four after it before it can be weighed.
        while liveNext + 4 < samples.count {
            live.append(LiveFrame(r: Self.ratio(samples, at: liveNext, period: 1 / trial.hz), p: samples[liveNext].p))
            liveNext += 1
        }
        if live.count > 400 { live.removeFirst(live.count - 400) }
        frameCount += 1
        if frameCount % 10 == 0 {
            briskSoFar = Double(Self.score(samples, hz: trial.hz).frames) / trial.hz
        }
        if briskSoFar >= Self.briskSeconds || now - phaseStart > Self.giveUpSeconds { finishTrial() }
    }

    private func track(_ fresh: [FrameSampler.Sample]) {
        guard !fresh.isEmpty else { return }
        let window = (samples + fresh).suffix(8)
        if let a = window.first, let b = window.last, b.t > a.t {
            velocity = CGVector(dx: (b.p.x - a.p.x) / (b.t - a.t), dy: (b.p.y - a.p.y) / (b.t - a.t))
            if hypot(b.p.x - a.p.x, b.p.y - a.p.y) > 1 { lastMotion = CACurrentMediaTime() }
        }
    }

    private func finishTrial() {
        let index = plan[position]
        let score = Self.score(samples, hz: trials[index].hz)
        trials[index].add(score)
        let gaps = zip(samples.dropFirst(), samples).map { $0.t - $1.t }.sorted()
        trials[index].attempts.append([
            "settled": settledAtRate ? 1 : 0,
            "periodMs": gaps.isEmpty ? 0 : gaps[gaps.count / 2] * 1000,
            "seconds": CACurrentMediaTime() - phaseStart,
            "frames": Double(score.frames),
        ])
        position += 1
        if position == plan.count, recheck.isEmpty, let pair = closestPair() {
            // The later of the two first: the one on screen now, if it is among them.
            plan += [max(pair.0, pair.1), min(pair.0, pair.1)]
            recheck = [trials[pair.0].hz, trials[pair.1].hz].sorted()
        }
        if position < plan.count {
            startTrial()
        } else {
            sampler.stop()
            restore()
            phase = .finished
        }
    }

    /// The best two rates, if the first round can't tell them apart: they differ by less than
    /// twice the likely error of that difference. Not when both are near perfect anyway.
    private func closestPair() -> (Int, Int)? {
        let ranked = trials.indices.filter { trials[$0].measured }.sorted { trials[$0].uneven < trials[$1].uneven }
        guard ranked.count >= 2 else { return nil }
        let a = trials[ranked[0]], b = trials[ranked[1]]
        let error = (a.spread * a.spread + b.spread * b.spread).squareRoot()
        guard b.uneven > 0.1, b.uneven - a.uneven < 2 * error else { return nil }
        return (ranked[0], ranked[1])
    }

    private func restore() {
        if let mode = originalMode, DisplayRates.currentMode(display) != mode { _ = DisplayRates.switchTo(display, mode: mode) }
    }

    struct Score { var frames = 0; var off = 0.0; var stalls = 0; var blocks: [Double] = []; var strip: [Double] = [] }

    /// A frame's step against the average step of the 9 frames around it; nil where a frame
    /// is missing or the hand moved too slowly to count.
    static func ratio(_ s: [FrameSampler.Sample], at i: Int, period: Double) -> Double? {
        guard i >= 5, i + 4 < s.count else { return nil }
        var sum = 0.0, mine = 0.0
        for k in (i - 4)...(i + 4) {
            guard s[k].t - s[k - 1].t < period * 1.6 else { return nil }
            let x = hypot(s[k].p.x - s[k - 1].p.x, s[k].p.y - s[k - 1].p.y)
            sum += x
            if k == i { mine = x }
        }
        let mean = sum / 9
        return mean >= briskSpeed * period ? mine / mean : nil
    }

    /// Every brisk frame, weighed. The mouse's own dropouts are left out: 20 ms or more with
    /// no movement, and the catch-up jump after, happen at any rate and say nothing about this one.
    static func score(_ s: [FrameSampler.Sample], hz: Double) -> Score {
        let period = 1 / hz
        let r = s.indices.map { ratio(s, at: $0, period: period) }
        var skip = [Bool](repeating: false, count: r.count)
        var i = 0
        while i < r.count {
            guard let x = r[i], x < 0.25 else { i += 1; continue }
            var j = i
            while j < r.count, let y = r[j], y < 0.25 { j += 1 }
            if Double(j - i) * period >= 0.02 { for k in i...min(j, r.count - 1) { skip[k] = true } }
            i = j
        }
        var score = Score()
        var run: [Double] = [], longest: [Double] = [], block: [Double] = []
        for (k, x) in r.enumerated() {
            guard let x, !skip[k] else {
                if run.count > longest.count { longest = run }
                run = []
                continue
            }
            let off = abs(min(x, 3) - 1)
            score.frames += 1
            score.off += off
            if x < 0.25 { score.stalls += 1 }
            run.append(x)
            block.append(off)
            if block.count == 30 {
                score.blocks.append(block.reduce(0, +) / 30)
                block = []
            }
        }
        if run.count > longest.count { longest = run }
        score.strip = Array(longest.suffix(120))
        return score
    }
}
