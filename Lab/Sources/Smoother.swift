import AppKit
import CoreGraphics
import QuartzCore
import os
import notify

enum SmoothingMode: String, CaseIterable, Identifiable {
    case smooth, balance, fast, faster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "Ровно"
        case .balance: return "Баланс"
        case .fast: return "Быстро"
        case .faster: return "Быстрее macOS"
        }
    }

    /// How far behind the newest report the cursor is drawn, as a share of one report
    /// interval plus 1 ms. Prediction bridges the rest of that span.
    var lagShare: Double {
        switch self {
        case .smooth: return 1
        case .balance: return 0.75
        case .fast: return 0.5
        case .faster: return 0.25
        }
    }

    /// Delay added on top of macOS, which shows a report as soon as it comes, so its
    /// cursor is on average half an interval old.
    func addedLatencyMs(period: Double) -> Double {
        ((period + 1e6) * lagShare - period / 2) / 1e6
    }

    var note: String {
        switch self {
        case .smooth: return "Самый ровный ход: курсор всегда идёт по уже известному пути, без предсказания."
        case .balance: return "Почти так же ровно; на быстрых движениях курсор немного предсказывает путь и отстаёт меньше."
        case .fast: return "На быстрых движениях отстаёт почти как macOS; ход чуть менее ровный."
        case .faster: return "На быстрых движениях курсор опережает macOS, но ход заметно менее ровный."
        }
    }
}

enum TrackpadPolicy: String, CaseIterable, Identifiable {
    case never, externalOnly, everywhere

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Не трогать"
        case .externalOnly: return "Только на внешних мониторах"
        case .everywhere: return "Везде"
        }
    }
}

struct SmootherSettings {
    var enabled = true
    var mode = SmoothingMode.smooth
    var trackpad = TrackpadPolicy.externalOnly
}

struct SmootherStatus {
    enum State { case starting, off, waiting, smoothing, gameMode, noAccess, failed }
    var state = State.starting
    var problem = ""
    var source = ""
    var display = ""
    var refreshHz = 0
    var periodMs = 0.0
    var tapLatencyMs = (median: 0.0, p99: 0.0)
    var wakeErrorMs = (median: 0.0, p99: 0.0)
}

/// The cursor path through the reports of one device, read at any moment.
struct Resampler {
    struct Sample { var t: Double; var u: Double; var x: Double; var y: Double }

    static let pause = 40e6
    private(set) var samples: [Sample] = []
    private(set) var period: Double
    private var intervals: [Double] = []

    init(period: Double) { self.period = period }

    mutating func reset() { samples.removeAll() }

    /// t: report time; (x, y): where macOS puts the cursor after it; rest: before it.
    mutating func add(t: Double, x: Double, y: Double, rest: CGPoint) {
        guard let last = samples.last, t - last.t <= Self.pause else {
            // Motion starts: the first report carries the movement of the interval before it.
            samples = [Sample(t: t - period, u: t - period, x: rest.x, y: rest.y), Sample(t: t, u: t, x: x, y: y)]
            return
        }
        let interval = t - last.t
        if interval > 2e6 && interval < 30e6 {
            intervals.append(interval)
            if intervals.count > 32 { intervals.removeFirst() }
            period = intervals.sorted()[intervals.count / 2]
        }
        // Bluetooth reports sit on a fixed grid; one that missed its slot arrives together
        // with the next. Two in one slot: the earlier belongs to the empty slot before it.
        var g: Double
        let n = ((t - last.u) / period).rounded()
        if n <= 0 {
            let c = samples.count
            if c >= 2 && samples[c - 1].u - period > samples[c - 2].u + period / 2 {
                samples[c - 1].u -= period
            }
            g = samples[c - 1].u + period
        } else {
            g = last.u + n * period
        }
        g += 0.05 * (t - g)   // follow the arrival phase so clock drift does not build up
        samples.append(Sample(t: t, u: g, x: x, y: y))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
    }

    /// Position at time tau, interpolated between reports, and the direction the path runs
    /// there. Past the newest report it predicts for at most maxPrediction, and only while
    /// reports are not overdue.
    func position(at tau: Double, now: Double, maxPrediction: Double) -> (point: CGPoint, direction: CGPoint)? {
        guard let last = samples.last else { return nil }
        var k = samples.count - 1
        while k >= 0 && samples[k].u > tau { k -= 1 }
        if k < 0 {
            let a = samples[0]
            let b = samples.count > 1 ? samples[1] : a
            return (CGPoint(x: a.x, y: a.y), CGPoint(x: b.x - a.x, y: b.y - a.y))
        }
        if k < samples.count - 1 {
            let a = samples[k], b = samples[k + 1]
            let direction = CGPoint(x: b.x - a.x, y: b.y - a.y)
            guard b.u - a.u <= Self.pause else { return (CGPoint(x: a.x, y: a.y), direction) }
            let w = (tau - a.u) / (b.u - a.u)
            return (CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w), direction)
        }
        let b = samples.count >= 2 ? samples[samples.count - 2] : last
        let direction = CGPoint(x: last.x - b.x, y: last.y - b.y)
        let h = min(tau - last.u, maxPrediction)
        let dt = last.u - b.u
        if h > 0, now - last.t <= 1.5 * period, dt > 0, dt <= Self.pause {
            return (CGPoint(x: last.x + direction.x / dt * h, y: last.y + direction.y / dt * h), direction)
        }
        return (CGPoint(x: last.x, y: last.y), direction)
    }

    /// How much prediction suits the motion now: 0 for slow or wavering motion, 1 for fast
    /// steady motion. Slow motion gains nothing from it (the cursor is less than a point
    /// behind), and its sparse, uneven reports make prediction overshoot and step back.
    func predictionWeight(now: Double) -> Double {
        let c = samples.count
        guard c >= 3, now - samples[c - 1].t <= 1.5 * period else { return 0 }
        let a = samples[c - 3], b = samples[c - 2], l = samples[c - 1]
        guard l.u - a.u > 0, l.u - a.u <= 2 * Self.pause else { return 0 }
        let m1 = hypot(b.x - a.x, b.y - a.y), m2 = hypot(l.x - b.x, l.y - b.y)
        guard m1 > 0, m2 > 0 else { return 0 }
        let cos = ((b.x - a.x) * (l.x - b.x) + (b.y - a.y) * (l.y - b.y)) / (m1 * m2)
        guard cos > 0.8, m2 / m1 > 0.6, m2 / m1 < 1.6 else { return 0 }
        let speed = hypot(l.x - a.x, l.y - a.y) / ((l.u - a.u) / 1e6)   // points per ms
        let x = min(max((speed - 0.3) / 1.2, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// Takes pointer motion away from macOS and puts the cursor on the path once per frame.
///
/// WindowServer keeps its own pointer position and adds every report's motion to it,
/// acceleration included: a real motion event's location is that position, whatever the
/// cursor on screen shows. Posting events or rewriting them moves only the cursor on
/// screen; a warp moves the pointer too but mutes the mouse for a moment. So an active tap
/// at the HID level drops the device's motion events, which leaves the cursor where we put
/// it, and keeps their locations as the path. A real-time thread wakes a little before
/// every vsync of the screen under the cursor and posts one event at the point the path
/// passed a mode-dependent delay ago.
final class Smoother: NSObject {
    static let shared = Smoother()
    /// eventSourceUserData of the events we post.
    static let marker: Int64 = 0x50534D
    /// Post this long before the vsync a position is meant for, so the cursor is in place
    /// when the display takes it.
    static let lead: Int64 = 2_000_000
    /// No poster run for this long while we hold the device's motion: give it back to macOS.
    static let stallLimit: Double = 80e6
    /// Consecutive motion events agree with their delta fields to about 1 pt. A bigger
    /// difference means someone else moved the pointer (a warp).
    static let jumpLimit = 4.0

    private struct Screen { var id: UInt32; var bounds: CGRect; var builtIn: Bool; var name: String; var fps: Int }
    private enum TapAction { case pass, drop, moveTo(CGPoint) }

    private struct State {
        var settings = SmootherSettings()
        var gameMode = false
        var tapRunning: Bool? = nil
        var failed: String? = nil

        var resampler = Resampler(period: 8e6)
        /// We hold the cursor: device motion goes to the path, not to the screen.
        var active = false
        var kind: Int64 = -1
        var source = ""
        /// Where the cursor is on screen.
        var cursor = CGPoint.zero
        /// WindowServer's own pointer position, from the newest motion event of a device.
        var pointer: CGPoint?
        var template: CGEvent?
        var buttons = 0
        var lastReal: Double = 0
        var waitingSince: Double?
        /// Current delay behind the newest report; eases toward the mode's as motion speeds up.
        var lag: Double = 0
        var lagAt: Double = 0

        var screens: [Screen] = []
        var displayID: UInt32 = 0
        var linksPaused = true
        var nextVsync: Int64 = 0

        var tapLatency: [Double] = []
        var wakeError: [Double] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let frameSignal = DispatchSemaphore(value: 0)
    private var tapPort: CFMachPort?
    private var displayThread: Thread!
    private var links: [CADisplayLink] = []
    private var linkTargets: [LinkTarget] = []
    private var gameModeToken: Int32 = 0

    private final class LinkTarget: NSObject {
        let displayID: UInt32
        init(_ id: UInt32) { displayID = id }
        @objc func tick(_ link: CADisplayLink) {
            Smoother.shared.vsync(displayID, target: Int64(link.targetTimestamp * 1e9))
        }
    }

    // MARK: - Setup

    func start(settings: SmootherSettings) {
        apply(settings)
        displayThread = Thread {
            RunLoop.current.add(Port(), forMode: .default)
            RunLoop.current.run()
        }
        displayThread.name = "pointersync.smoother.display"
        displayThread.qualityOfService = .userInteractive
        displayThread.start()
        rebuildScreens()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let tapThread = Thread { [self] in runTap() }
        tapThread.name = "pointersync.smoother.tap"
        tapThread.qualityOfService = .userInteractive
        tapThread.start()

        let poster = Thread { [self] in runPoster() }
        poster.name = "pointersync.smoother.poster"
        poster.qualityOfService = .userInteractive
        poster.start()

        watchGameMode()
    }

    func apply(_ settings: SmootherSettings) {
        state.withLock { s in s.settings = settings }
    }

    func status() -> SmootherStatus {
        state.withLock { s in
            var st = SmootherStatus()
            let screen = s.screens.first { $0.id == s.displayID }
            st.display = screen?.name ?? ""
            st.refreshHz = screen?.fps ?? 0
            st.periodMs = s.resampler.period / 1e6
            st.source = s.source
            st.tapLatencyMs = (Self.percentile(s.tapLatency, 0.5) / 1e6, Self.percentile(s.tapLatency, 0.99) / 1e6)
            st.wakeErrorMs = (Self.percentile(s.wakeError, 0.5) / 1e6, Self.percentile(s.wakeError, 0.99) / 1e6)
            if s.tapRunning == false { st.state = .noAccess }
            else if s.tapRunning == nil { st.state = .starting }
            else if let f = s.failed { st.state = .failed; st.problem = f }
            else if !s.settings.enabled { st.state = .off }
            else if s.gameMode { st.state = .gameMode }
            else if s.active && Double(Clock.now()) - s.lastReal < 300e6 { st.state = .smoothing }
            else { st.state = .waiting }
            return st
        }
    }

    /// Lets smoothing start again after it gave up.
    func retry() { state.withLock { s in s.failed = nil; s.waitingSince = nil } }

    @objc private func screensChanged() { rebuildScreens() }

    private func rebuildScreens() {
        links.forEach { $0.invalidate() }
        links = []
        linkTargets = []
        var screens: [Screen] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let fps = screen.maximumFramesPerSecond
            screens.append(Screen(id: id, bounds: CGDisplayBounds(id), builtIn: CGDisplayIsBuiltin(id) != 0,
                                  name: screen.localizedName, fps: fps))
            let target = LinkTarget(id)
            let link = screen.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            link.isPaused = true
            linkTargets.append(target)
            links.append(link)
            perform(#selector(attach(_:)), on: displayThread, with: link, waitUntilDone: false)
        }
        let list = screens
        state.withLock { s in
            s.screens = list
            s.linksPaused = true
        }
    }

    @objc private func attach(_ link: CADisplayLink) { link.add(to: .current, forMode: .common) }

    @objc private func setLinksPaused(_ paused: NSNumber) {
        links.forEach { $0.isPaused = paused.boolValue }
    }

    private func watchGameMode() {
        let status = notify_register_dispatch("com.apple.gamepolicy.game-mode-session", &gameModeToken, .main) { [weak self] token in
            self?.readGameMode(token)
        }
        if status == 0 { readGameMode(gameModeToken) }
    }

    private func readGameMode(_ token: Int32) {
        var value: UInt64 = 0
        notify_get_state(token, &value)
        let on = value != 0
        state.withLock { s in s.gameMode = on }
    }

    // MARK: - Tap: take the device's motion

    private func runTap() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
                                               Smoother.shared.handle(type, event)
                                           }, userInfo: nil) else {
            state.withLock { $0.tapRunning = false }
            return
        }
        tapPort = port
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        state.withLock { $0.tapRunning = true }
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            state.withLock { s in s.active = false; s.resampler.reset() }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return pass }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let bit = 1 << Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            // A click belongs where the cursor is drawn, not where WindowServer's pointer is.
            let at: CGPoint? = state.withLock { s in
                s.buttons = down ? s.buttons | bit : s.buttons & ~bit
                return s.active ? s.cursor : nil
            }
            if let at { event.location = at }
            return pass
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return pass
        }

        let now = Double(Clock.now())
        let t = Double(Clock.eventTime(event.timestamp))
        let sub = event.getIntegerValueField(.mouseEventSubtype)
        let fromDevice = event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        let location = event.location
        let delta = CGPoint(x: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                            y: Double(event.getIntegerValueField(.mouseEventDeltaY)))

        let (action, wakeLinks): (TapAction, Bool) = state.withLock { s in
            s.tapLatency.append(now - t)
            if s.tapLatency.count > 512 { s.tapLatency.removeFirst(256) }
            if let since = s.waitingSince, now - since > Self.stallLimit, s.failed == nil {
                s.failed = "Поток вывода курсора не отвечает"
            }

            let previous = s.pointer
            if fromDevice { s.pointer = location }
            let screen = s.screens.first { $0.bounds.contains(location) }
            let trackpadOK = s.settings.trackpad == .everywhere
                || (s.settings.trackpad == .externalOnly && screen?.builtIn == false)
            let wanted = s.settings.enabled && !s.gameMode && s.failed == nil && fromDevice
                && (sub == 0 || (sub == 3 && trackpadOK))
            // Moved by someone else (a warp), or nothing to follow yet.
            let jumped = previous.map { hypot(location.x - $0.x - delta.x, location.y - $0.y - delta.y) > Self.jumpLimit } ?? true
            guard wanted && !jumped else {
                // macOS shows its pointer as usual; if we were holding the cursor back, it
                // catches up here. A later event takes over again.
                s.active = false
                s.resampler.reset()
                s.cursor = location
                return (.pass, false)
            }
            if !s.active || s.kind != sub {
                // Take over from where the cursor is now, which is where macOS had the pointer.
                s.active = true
                s.kind = sub
                s.source = sub == 3 ? "трекпад" : "мышь"
                s.resampler.reset()
                if let p = previous { s.cursor = p }
            }
            s.resampler.add(t: t, x: location.x, y: location.y, rest: s.cursor)
            s.template = event.copy()
            s.lastReal = now
            if s.waitingSince == nil { s.waitingSince = now }
            s.displayID = (s.screens.first { $0.bounds.contains(s.cursor) } ?? screen)?.id ?? s.displayID
            let wake = s.linksPaused
            s.linksPaused = false
            return (.drop, wake)
        }

        if wakeLinks { perform(#selector(setLinksPaused(_:)), on: displayThread, with: NSNumber(value: false), waitUntilDone: false) }
        if fromDevice {
            var held = false
            if case .drop = action { held = true }
            Recorder.shared.add(PointerSample(t: Int64(t), r: Int64(now), x: location.x, y: location.y, held: held))
        }
        switch action {
        case .pass: return pass
        case .drop: return nil
        case .moveTo(let p): event.location = p; return pass
        }
    }

    // MARK: - Poster: one cursor update per frame

    private func vsync(_ displayID: UInt32, target: Int64) {
        let mine = state.withLock { s -> Bool in
            guard displayID == s.displayID else { return false }
            s.nextVsync = target
            return true
        }
        if mine { frameSignal.signal() }
    }

    private func runPoster() {
        Self.makeRealtime()
        while true {
            frameSignal.wait()
            while frameSignal.wait(timeout: .now()) == .success {}   // only the newest frame matters
            let vsync = state.withLock { $0.nextVsync }
            let deadline = vsync - Self.lead
            if deadline > Clock.now() { mach_wait_until(Clock.ticks(fromNs: deadline)) }
            postFrame(deadline: deadline)
        }
    }

    private enum PostAction { case none, pause, post(CGEvent, CGPoint, CGPoint, CGEventType) }

    private func postFrame(deadline: Int64) {
        let nowNs = Clock.now()
        let now = Double(nowNs)
        let action: PostAction = state.withLock { s in
            s.waitingSince = nil
            s.wakeError.append(Double(nowNs - deadline))
            if s.wakeError.count > 512 { s.wakeError.removeFirst(256) }
            guard s.active, s.failed == nil, let template = s.template else {
                if !s.linksPaused && now - s.lastReal > 250e6 { s.linksPaused = true; return .pause }
                return .none
            }
            let full = s.resampler.period + 1e6
            // Predict only fast, steady motion; otherwise draw from the known path. The lag
            // changes slowly enough that the drawn time never runs backward.
            let target = full - s.resampler.predictionWeight(now: now) * full * (1 - s.settings.mode.lagShare)
            if now - s.lagAt > 100e6 { s.lag = target }
            else {
                let step = 0.25 * (now - s.lagAt)
                s.lag = min(max(target, s.lag - step), s.lag + step)
            }
            s.lagAt = now
            guard let (q, direction) = s.resampler.position(at: now - s.lag, now: now, maxPrediction: full - s.lag)
            else { return .none }
            // Never step against the way the path runs: that reads as a shake and makes
            // macOS enlarge the pointer.
            var p = q
            if direction.x * (p.x - s.cursor.x) < 0 { p.x = s.cursor.x }
            if direction.y * (p.y - s.cursor.y) < 0 { p.y = s.cursor.y }
            let d = CGPoint(x: p.x - s.cursor.x, y: p.y - s.cursor.y)
            if abs(d.x) < 1e-3 && abs(d.y) < 1e-3 {
                if now - s.lastReal > 250e6 { s.linksPaused = true; return .pause }
                return .none
            }
            s.cursor = p
            s.displayID = s.screens.first { $0.bounds.contains(p) }?.id ?? s.displayID
            let type: CGEventType = s.buttons & 1 != 0 ? .leftMouseDragged
                : s.buttons & 2 != 0 ? .rightMouseDragged
                : s.buttons != 0 ? .otherMouseDragged : .mouseMoved
            return .post(template, p, d, type)
        }
        switch action {
        case .none:
            return
        case .pause:
            perform(#selector(setLinksPaused(_:)), on: displayThread, with: NSNumber(value: true), waitUntilDone: false)
        case .post(let template, let p, let d, let type):
            guard let e = template.copy() else { return }
            e.type = type
            e.location = p
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.x.rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.y.rounded()))
            e.setDoubleValueField(.mouseEventDeltaX, value: d.x)
            e.setDoubleValueField(.mouseEventDeltaY, value: d.y)
            e.timestamp = Clock.eventStamp(like: template.timestamp)
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cghidEventTap)
        }
    }

    private static func makeRealtime() {
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(Clock.ticks(fromNs: 6_000_000)),
            computation: UInt32(Clock.ticks(fromNs: 300_000)),
            constraint: UInt32(Clock.ticks(fromNs: 1_000_000)),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &policy) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                      thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }

    private static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }
}
