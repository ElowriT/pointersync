import AppKit
import Combine
import SwiftUI

/// The whole setup: welcome, test every rate, pick one, switch, confirm, done.
@MainActor
final class SetupModel: ObservableObject {
    enum Stage: Equatable { case welcome, measure, result, folding, confirm, done }
    enum Hint { case start, moving, slow, switching }
    /// Why the little window with how to move the mouse is up: the hand rests, or crawls.
    enum Coach: Equatable { case still, slow }
    /// A shape drawn with the cursor on the start screen, and when: an easter egg.
    struct Reaction: Equatable {
        var doodle: Doodle
        var at: Double
    }
    enum Panel: Equatable { case settings, about, quit }

    @Published var stage = Stage.welcome
    @Published var panel: Panel?
    @Published var progress = 0.0
    @Published var hint = Hint.start
    @Published var testingHz: Double?
    @Published var testNumber = 0
    @Published var testCount = 0
    @Published var deviceName = ""
    @Published var transport = ""
    @Published var trackpad = false
    /// The frames being recorded, for the live picture (see `RateTester.live`).
    @Published var live: [LiveFrame] = []
    @Published var liveHz = 0.0
    /// The two rates being tried a second time, while that goes on.
    @Published var recheck: [Double] = []
    @Published var coach: Coach?
    @Published var reaction: Reaction?
    static let reactionSeconds = 3.5
    @Published var trials: [RateTrial] = []
    /// The run before this one on the same mouse and screen, rate by rate, to see if it repeats.
    @Published var previous: [Double: Double] = [:]
    @Published var previousRecommended: Double?
    @Published var screenName = ""
    @Published var originalHz = 0.0
    @Published var recommended: Double?
    @Published var selected: Double?
    @Published var countdown = 0.0
    @Published var notice: String?
    @Published var kept: Double?

    static let confirmSeconds = 15.0

    /// Set once the user agreed to quit, so the next terminate goes through.
    var quitConfirmed = false
    private var previewing = false

    private let tester = RateTester()
    private let watcher = DeviceWatcher()
    private var display: UInt32 = 0
    private var deadline = Date()
    private var switchedFrom: Int32?
    private var settingsWatch: AnyCancellable?
    private var previousKey = ""
    private var stillSince: Double?
    private var slowSince: Double?
    private let doodles = DoodleWatcher()
    private var lastReaction = -100.0
    private var nextHint: Hint?
    private var nextHintSince = 0.0
    private var runKey: String { "\(deviceName)|\(screenName)" }

    init() {
        // `--doodle-log`: every drawing on the start screen, weighed, one JSON line each, into
        // ~/Library/Application Support/PointerSync/doodles.jsonl, to tune the easter egg.
        if CommandLine.arguments.contains("--doodle-log") {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PointerSync", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("doodles.jsonl")
            doodles.log = { entry in
                var line = entry
                line["at"] = ISO8601DateFormatter().string(from: Date())
                guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
                data.append(0x0A)
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: file)
                }
            }
        }
        // A changed priority re-picks the rate from the same measurements.
        settingsWatch = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { if self?.stage == .result { self?.recommend() } }
        }
    }

    /// "MX Master 3S", or a plain word for an unnamed device, in the case the sentence needs.
    func deviceTitle(genitive: Bool) -> String {
        if !deviceName.isEmpty { return deviceName }
        if trackpad { return genitive ? tr("трекпада", "your trackpad") : tr("Трекпад", "Your trackpad") }
        return genitive ? tr("твоей мыши", "your mouse") : tr("Мышь", "Your mouse")
    }

    var measuredTrials: [RateTrial] { trials.filter(\.measured).sorted { $0.hz < $1.hz } }
    func trial(_ rate: Double?) -> RateTrial? { trials.first { $0.hz == rate } }

    /// The mouse's report rate, as far as the screen can tell: at a rate above it, the share
    /// of frames that get a new position. Nil when even the fastest rate got one every frame.
    var mouseRate: Double? {
        guard let top = measuredTrials.last, top.stalls > 0.03 else { return nil }
        return (1 - top.stalls) * top.hz
    }

    /// "MX Master 3S (≈131 reports a second) on Mi Monitor", for the result's subtitle.
    var forWhat: String {
        let rate = mouseRate.map { r -> String in
            let n = Int(r.rounded())
            return tr(" (≈\(n) \(ruPlural(n, "сигнал", "сигнала", "сигналов")) в секунду)", " (≈\(n) reports a second)")
        } ?? ""
        // Names stay whole on a line.
        let device = deviceTitle(genitive: true).replacingOccurrences(of: " ", with: "\u{00A0}")
        let screen = screenName.replacingOccurrences(of: " ", with: "\u{00A0}")
        return tr("\(device)\(rate) на \(screen)", "\(device)\(rate) on \(screen)")
    }

    /// Whether the run before this one picked the same rate.
    var againNote: String {
        guard let before = previousRecommended, let now = recommended else { return "" }
        return before == now ? tr(" Как и в прошлый раз.", " Same as last time.")
                             : tr(" В прошлый раз — \(hz(before)).", " Last time: \(hz(before)).")
    }

    var yourPickNote: String {
        tr("Твой выбор. По замеру лучше всего \(recommended.map(hz) ?? "—").", "Your pick. The test liked \(recommended.map(hz) ?? "—") best.")
    }

    var doneMessage: String {
        let rate = selected.map(hz) ?? ""
        if kept != nil {
            return tr("\(screenName) остаётся на \(rate) — это и есть лучший вариант. Приложение можно закрыть.",
                      "\(screenName) stays at \(rate) — that's already the best. You can close the app.")
        }
        return tr("\(screenName) теперь на \(rate). Это сохранится — приложение можно закрыть и больше не открывать.",
                  "\(screenName) now runs at \(rate). It stays that way — close the app and you won't need it again.")
    }

    // MARK: - Measuring

    func startMeasuring() {
        guard !previewing, let screen = NSApp.keyWindow?.screen ?? NSScreen.main, let id = Self.displayID(screen) else { return }
        if !measuredTrials.isEmpty {
            previous = Dictionary(uniqueKeysWithValues: measuredTrials.map { ($0.hz, $0.smooth) })
            previousRecommended = recommended
            previousKey = runKey
        }
        display = id
        screenName = screen.localizedName
        watcher.reset()
        watcher.start()
        notice = nil
        kept = nil
        progress = 0
        hint = .start
        live = []
        recheck = []
        coach = nil
        reaction = nil
        doodles.reset()
        stillSince = nil
        slowSince = nil
        tester.begin(on: screen)
        originalHz = tester.originalHz
        testCount = tester.trials.count
        stage = .measure
    }

    /// Called every frame of the window's screen.
    func frame() {
        // On the start screen, see whether the cursor draws something, while the app is in
        // front: from behind other windows, nobody draws in its dial.
        if stage == .welcome, panel == nil, !previewing, let p = CursorTrail.shared.points.last {
            if NSApp.isActive {
                let now = CACurrentMediaTime()
                // The drawing as the dial's trail shows it: the hand's path, scaled down. The
                // canvas under it only slides it about.
                let shown = CGPoint(x: p.x * CursorTrail.canvasScale, y: p.y * CursorTrail.canvasScale)
                if let doodle = doodles.step(real: p, shown: shown, now: now), now - lastReaction > 6 { react(doodle, at: now) }
            } else {
                doodles.reset()
            }
        }
        guard stage == .measure, !previewing else { return }
        tester.step()
        progress = tester.progress
        live = tester.live
        liveHz = tester.liveHz
        recheck = tester.recheck
        testNumber = min(tester.position + 1, testCount)
        testingHz = tester.current?.hz
        if let device = watcher.main {
            deviceName = device.name
            transport = device.transport
            trackpad = device.trackpad
        }
        let now = CACurrentMediaTime()
        let moving = now - tester.lastMotion < 0.3
        let slow = moving && hypot(tester.velocity.dx, tester.velocity.dy) < RateTester.briskSpeed
        // A new hint has to hold for a quarter second (switching shows at once), so the flipping
        // letters don't chatter while the hand's speed hovers around the line.
        let next: Hint = tester.phase == .settling ? .switching : !moving ? .start : slow ? .slow : .moving
        if next == hint {
            nextHint = nil
        } else if next != nextHint {
            nextHint = next
            nextHintSince = now
        }
        if let pending = nextHint, pending == .switching || now - nextHintSince > 0.25 {
            hint = pending
            nextHint = nil
        }
        // Show how to move after a moment of rest, or of crawling; once up, until the hand
        // moves briskly.
        stillSince = moving ? nil : (stillSince ?? now)
        slowSince = slow ? (slowSince ?? now) : nil
        let up = coach != nil
        let want: Coach? = !moving && (up || now - (stillSince ?? now) > 1.5) ? .still
                         : slow && (up || now - (slowSince ?? now) > 3) ? .slow : nil
        if want != coach { coach = want }
        if tester.phase == .finished { finishMeasuring() }
    }

    /// A heart, a star or the other one, answered for a few seconds.
    private func react(_ doodle: Doodle, at now: Double) {
        lastReaction = now
        let reaction = Reaction(doodle: doodle, at: now)
        withAnimation(.smooth) { self.reaction = reaction }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reactionSeconds) { [weak self] in
            guard let self, self.reaction == reaction else { return }
            withAnimation(.smooth) { self.reaction = nil }
        }
    }

    /// Stops a test half way: the screen goes back to its rate and the app to the start.
    func stopMeasuring() {
        guard stage == .measure, !previewing else { return }
        tester.abort()
        watcher.stop()
        coach = nil
        notice = tr("Проверка остановлена. Экран снова на \(hz(originalHz)).", "Test stopped. The display is back at \(hz(originalHz)).")
        stage = .welcome
    }

    private func finishMeasuring() {
        watcher.stop()
        coach = nil
        if previousKey != runKey {
            previous = [:]
            previousRecommended = nil
        }
        trials = tester.trials
        recommend()
        selected = recommended ?? originalHz
        saveLastMeasurement()
        stage = .result
    }

    /// The rate where the cursor moves most evenly. Rates within a hair of it count as equal:
    /// then the one with more frames, or the current one if it is among them (no switch for nothing).
    func recommend() {
        let list = measuredTrials
        guard let top = list.map(\.hz).max() else { recommended = nil; return }
        let weight = Settings.shared.priority.frameWeight
        func score(_ t: RateTrial) -> Double { t.uneven + weight * (1 - t.hz / top) }
        guard let lowest = list.map(score).min() else { return }
        let equal = list.filter { score($0) - lowest < 0.02 }
        recommended = equal.first { abs($0.hz - originalHz) < 0.5 }?.hz ?? equal.map(\.hz).max()
    }

    /// The last measurement, for a look if a result ever seems off.
    private func saveLastMeasurement() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PointerSync", isDirectory: true)
        let record: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "device": deviceName, "transport": transport, "trackpad": trackpad,
            "screen": screenName, "originalHz": originalHz, "recommendedHz": recommended ?? 0,
            "recheck": tester.recheck,
            "trials": trials.map { ["hz": $0.hz, "frames": $0.frames, "uneven": $0.uneven, "spread": $0.spread, "stalls": $0.stalls,
                                    "blocks": $0.blocks, "attempts": $0.attempts, "strip": $0.strip] as [String: Any] },
        ]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: folder.appendingPathComponent("last-measurement.json"))
        }
    }

    // MARK: - Switching

    func apply() {
        guard !previewing, let rate = selected else { return }
        panel = nil
        guard abs(rate - originalHz) > 0.5 else {   // keeping what is there
            kept = rate
            stage = .done
            return
        }
        stage = .folding
        // Let the fold play, then switch: the screen blinks for a moment as the mode changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            switchedFrom = DisplayRates.currentMode(display)
            guard DisplayRates.switchTo(display, hz: rate) else {
                notice = tr("Не получилось переключить частоту. Её можно поменять в Системных настройках → Дисплеи.",
                            "Couldn't switch the refresh rate. You can change it in System Settings → Displays.")
                stage = .result
                return
            }
            deadline = Date().addingTimeInterval(Self.confirmSeconds)
            countdown = Self.confirmSeconds
            stage = .confirm
            tickConfirm()
        }
    }

    private func tickConfirm() {
        guard stage == .confirm else { return }
        countdown = max(0, deadline.timeIntervalSinceNow)
        if countdown == 0 { revert(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in self?.tickConfirm() }
    }

    func keep() {
        guard !previewing else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        stage = .done
    }

    /// Puts the screen back to the mode it had before the switch.
    func revert() {
        guard !previewing else { return }
        if let mode = switchedFrom { _ = DisplayRates.switchTo(display, mode: mode) }
        switchedFrom = nil
        notice = tr("Вернул \(hz(originalHz)).", "Switched back to \(hz(originalHz)).")
        stage = .result
    }

    // MARK: - Quitting

    func askToQuit() { panel = .quit }

    func confirmQuit() {
        quitConfirmed = true
        NSApp.terminate(nil)
    }

    /// Leaves the screen as the user last agreed to.
    func cleanUpBeforeQuit() {
        tester.abort()
        if stage == .confirm { revert() }
    }

    /// What quitting now would leave behind, for the question.
    var quitConsequence: String {
        switch stage {
        case .measure: return tr("Проверка прервётся, частота вернётся к \(hz(originalHz)).", "The test stops and the rate goes back to \(hz(originalHz)).")
        case .confirm, .folding: return tr("Частота вернётся к \(hz(originalHz)).", "The rate goes back to \(hz(originalHz)).")
        case .done: return tr("Настройка уже сохранена.", "Your setting is saved.")
        case .result: return tr("Частота экрана останется \(hz(originalHz)).", "The display stays at \(hz(originalHz)).")
        case .welcome: return tr("Ничего не изменится.", "Nothing will change.")
        }
    }

    // MARK: - Preview

    /// `--preview welcome|measure|result|confirm|done|settings|about|quit`: a stage with
    /// made-up trials of a 133 Hz Bluetooth mouse, to look at the screens without one.
    func preview(_ name: String) {
        previewing = true
        deviceName = "MX Master 3S"
        transport = "Bluetooth"
        // A screen PointerSync is for: an external one, if there is one.
        let external = NSScreen.screens.first { Self.displayID($0).map { CGDisplayIsBuiltin($0) == 0 } ?? false }
        screenName = (external ?? NSScreen.main)?.localizedName ?? "Display"
        originalHz = 165
        trials = [165, 144, 120, 100].map { Self.fakeTrial(hz: $0) }
        recommend()
        selected = recommended
        // A hand circling once a second, 300 points round, two thirds of the way.
        let turn = 0.68
        CursorTrail.shared.preview(radius: 300, turn: turn)
        if let fake = trials.first(where: { $0.hz == 144 }) {
            live = (0..<130).map { k -> LiveFrame in
                let a = 2 * .pi * (turn - Double(129 - k) / 144) - .pi / 2
                return LiveFrame(r: fake.strip[k % fake.strip.count], p: CGPoint(x: 300 * cos(a), y: 300 * sin(a)))
            }
            liveHz = 144
        }
        switch name {
        case "measure": progress = 0.38; hint = .moving; testingHz = 144; testNumber = 2; testCount = 4; stage = .measure
        case "recheck": progress = 0.86; hint = .moving; testingHz = 144; recheck = [120, 144]; stage = .measure
        case "coach": progress = 0.12; hint = .start; testingHz = 165; testNumber = 1; testCount = 4; coach = .still; stage = .measure
        case "heart", "star", "rude":
            reaction = Reaction(doodle: Doodle(rawValue: name) ?? .heart, at: CACurrentMediaTime() - 0.3)
            stage = .welcome
        case "stopped":
            notice = tr("Проверка остановлена. Экран снова на \(hz(originalHz)).", "Test stopped. The display is back at \(hz(originalHz)).")
            stage = .welcome
        case "again":
            previous = [165: 0.57, 144: 0.86, 120: 0.80, 100: 0.69]
            previousRecommended = recommended
            stage = .result
        case "result": stage = .result
        case "confirm": countdown = 11.4; stage = .confirm
        case "done": stage = .done
        case "settings": stage = .result; panel = .settings
        case "about": panel = .about
        case "quit": stage = .result; panel = .quit
        default: stage = .welcome
        }
    }

    /// What a steady 133 Hz mouse looks like at `hz`: the steps of 120 frames, each against
    /// the 9 around it.
    private static func fakeTrial(hz: Double) -> RateTrial {
        let report = 1000 / 133.3, frame = 1000 / hz
        let counts = (0..<128).map { k -> Double in
            let a = Double(k) * frame, b = a + frame
            return Double(Int((b / report).rounded(.down)) - Int((a / report).rounded(.down)))
        }
        let strip = (4..<124).map { i in counts[i] / (counts[(i - 4)...(i + 4)].reduce(0, +) / 9) }
        let off = strip.map { abs(min($0, 3) - 1) }
        var trial = RateTrial(hz: hz, mode: 0)
        trial.add(RateTester.Score(frames: off.count, off: off.reduce(0, +), stalls: strip.filter { $0 < 0.25 }.count,
                                   blocks: stride(from: 0, to: 120, by: 30).map { off[$0..<$0 + 30].reduce(0, +) / 30 },
                                   strip: strip))
        return trial
    }

    static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
