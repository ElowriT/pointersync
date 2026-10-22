import AppKit
import SwiftUI
import IOKit.hid

final class AppModel: ObservableObject {
    @Published var sources: [SourceResult] = []
    @Published var clocks: [ScreenClock] = []
    @Published var status = Status()
    @Published var deviceCount = 0
    @Published var now: Int64 = Clock.now()
    @Published var savedPath: String?
    @Published var smoother = SmootherStatus()
    @Published var rateSources: [RateSource] = []
    @Published var rateSourceID: String?
    @Published var rateMessage: String?
    /// "Shake to locate" enlargements in the last two minutes, and how many came while
    /// the smoother was holding the cursor.
    @Published var enlargements = (total: 0, whileSmoothing: 0)
    @Published var smoothingEnabled: Bool { didSet { settingsChanged() } }
    @Published var mode: SmoothingMode { didSet { settingsChanged() } }
    @Published var trackpad: TrackpadPolicy { didSet { settingsChanged() } }

    init() {
        let d = UserDefaults.standard
        smoothingEnabled = d.object(forKey: "smoothingEnabled") as? Bool ?? true
        mode = SmoothingMode(rawValue: d.string(forKey: "mode") ?? "") ?? .smooth
        trackpad = TrackpadPolicy(rawValue: d.string(forKey: "trackpad") ?? "") ?? .externalOnly
    }

    var settings: SmootherSettings { SmootherSettings(enabled: smoothingEnabled, mode: mode, trackpad: trackpad) }

    private func settingsChanged() {
        let d = UserDefaults.standard
        d.set(smoothingEnabled, forKey: "smoothingEnabled")
        d.set(mode.rawValue, forKey: "mode")
        d.set(trackpad.rawValue, forKey: "trackpad")
        Smoother.shared.apply(settings)
    }

    /// Results stay on screen after the hand moves to another device, so both can be compared.
    private var sticky: [String: SourceResult] = [:]
    private var order: [String] = []
    private var timer: Timer?
    private var ticks = 0

    static let window: Int64 = 6_000_000_000
    static let keep: Int64 = 300_000_000_000

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let t = Clock.now()
        ticks += 1
        if ticks % 4 == 1 {
            Recorder.shared.updateStatus {
                $0.hidAccess = Int(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
                $0.listenAccess = CGPreflightListenEventAccess()
            }
        }
        Recorder.shared.trim(before: t - Self.keep)
        if ticks % 4 == 1 {
            let long = Recorder.shared.snapshot(since: t - RateMatcher.window)
            rateSources = RateMatcher.advise(long, now: t)
            let onsets = CursorScale.enlargements(long.scales)
            let held = long.pointer.filter(\.held).map(\.r)
            let smoothing = onsets.filter { o in held.contains { $0 <= o && o - $0 < 1_000_000_000 } }
            enlargements = (onsets.count, smoothing.count)
        }
        let snap = Recorder.shared.snapshot(since: t - Self.window)
        let analysis = Analyzer.run(snap, now: t)
        for s in analysis.sources {
            if var old = sticky[s.id] {
                for screen in s.screens {
                    if let i = old.screens.firstIndex(where: { $0.id == screen.id }) { old.screens[i] = screen }
                    else { old.screens.append(screen) }
                }
                old.timing = s.timing ?? old.timing
                sticky[s.id] = old
            } else {
                sticky[s.id] = s
                order.append(s.id)
            }
        }
        sources = order.compactMap { sticky[$0] }
        clocks = analysis.clocks
        status = snap.status
        deviceCount = snap.devices.count
        smoother = Smoother.shared.status()
        now = t
    }

    var selectedRateSource: RateSource? {
        rateSources.first { $0.id == rateSourceID } ?? rateSources.first
    }

    func switchRate(_ display: UInt32, _ hz: Double) {
        rateMessage = RateMatcher.switchTo(display, hz: hz) ? nil : "Не удалось переключить частоту"
        ticks = 0   // re-evaluate right away
    }

    func reset() {
        Recorder.shared.clear()
        sticky = [:]
        order = []
        sources = []
        savedPath = nil
    }

    func save(auto: Bool = false) {
        if auto && sources.isEmpty { return }
        do { savedPath = try Exporter.save(summary: summaryLines()).path }
        catch { savedPath = "Не удалось сохранить: \(error.localizedDescription)" }
    }

    func summaryLines() -> [String] {
        var lines: [String] = clocks.map { "Экран \($0.name): \($0.nominalHz) Гц, замерено \(f1($0.measuredHz))" }
        for s in sources {
            var line = "\(s.title) (\(s.subtitle))"
            if let t = s.timing {
                line += ": отчёты \(f0(t.hz)) Гц, интервал \(f1(t.medianMs)) мс [\(f1(t.p10Ms))–\(f1(t.p90Ms))], опоздавших \(pct(t.lateShare)), слипшихся \(pct(t.bunchedShare)), задержка HID \(f2(t.latencyMedianMs)) мс"
            }
            lines.append(line)
            for r in s.screens {
                lines.append("  \(r.name) \(f0(r.refreshHz)) Гц: события \(f0(r.eventHz)) Гц, кадров \(r.frames), обновлений за кадр 0/1/2/3+ = \(r.hist.map { pct($0) }.joined(separator: "/")), неровность \(pct(r.unevenMedian)) (p95 \(pct(r.unevenP95))), стоп-кадров \(pct(r.stallShare)), скачков \(pct(r.jumpShare)); со сглаживанием \(pct(r.smoothUnevenMedian)) (p95 \(pct(r.smoothUnevenP95))), +\(f1(r.addedLatencyMs)) мс; задержка события \(f2(r.tapLatencyMedianMs)) мс (p99 \(f2(r.tapLatencyP99Ms)))")
            }
        }
        return lines
    }

    func revealSaved() {
        NSWorkspace.shared.activateFileViewerSelecting([Exporter.folder])
    }

    func openPrivacySettings(_ pane: String = "Privacy_ListenEvent") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

func f0(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0))) }
func f1(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(1))) }
func f2(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(2))) }
func pct(_ x: Double) -> String { (x * 100).formatted(.number.precision(.fractionLength(0))) + "%" }

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Замер плавности курсора").font(.title2.weight(.semibold))
                    Text("Поводите курсором кругами 5–10 секунд, ровно и без остановок. Сначала мышью, потом трекпадом. Результаты каждого устройства остаются на экране.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RateView(model: model)
                SmoothingView(model: model)
                Text("Замер").font(.title3.weight(.semibold)).padding(.top, 4)
                PermissionsView(model: model)
                if !model.clocks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.clocks) { c in
                            Text("Экран \(c.name): \(c.nominalHz) Гц, по замеру \(f1(c.measuredHz)) Гц")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.sources.isEmpty {
                    GroupBox {
                        Text("Пока нет данных — подвигайте курсором.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                ForEach(model.sources) { SourceCard(source: $0, now: model.now) }
                HStack {
                    Button("Сохранить замер") { model.save() }.keyboardShortcut("s")
                    Button("Показать в Finder") { model.revealSaved() }
                    Spacer()
                    Button("Сбросить") { model.reset() }
                }
                if let path = model.savedPath {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 580, minHeight: 640)
    }
}

struct PermissionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.status
        let hidOK = s.hidOpen == 0
        let tapOK = s.tapRunning == true
        VStack(alignment: .leading, spacing: 4) {
            row(hidOK, hidOK ? "Устройства ввода: читаю напрямую (\(model.deviceCount))"
                             : s.hidOpen == nil ? "Устройства ввода: подключаюсь…"
                             : "Устройства ввода: нет доступа (код \(String(format: "0x%08x", s.hidOpen!)))")
            row(tapOK, tapOK ? "События курсора: слушаю"
                             : s.tapRunning == nil ? "События курсора: запускаюсь…"
                             : "События курсора: нет доступа")
            if !(hidOK && tapOK) || s.hidAccess == 1 {
                Text("Нужно разрешение «Мониторинг ввода» для PointerSync. После включения перезапустите приложение.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Открыть настройки") { model.openPrivacySettings() }
                    Button("Перезапустить") { model.relaunch() }
                }
            }
        }
    }

    private func row(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
            .font(.callout)
    }
}

struct SourceCard: View {
    let source: SourceResult
    let now: Int64

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let t = source.timing {
                    Text("Отчёты устройства: \(f0(t.hz)) Гц · интервал \(f1(t.medianMs)) мс (обычно \(f1(t.p10Ms))–\(f1(t.p90Ms)) мс)")
                    Text("Опоздавших отчётов: \(pct(t.lateShare)) · слипшихся с предыдущим: \(pct(t.bunchedShare))")
                    Text("Задержка до программы: \(f2(t.latencyMedianMs)) мс (худший 1%: \(f2(t.latencyP99Ms)) мс)")
                        .foregroundStyle(.secondary)
                }
                ForEach(source.screens) { ScreenBlock(r: $0, now: now, smoothed: source.smoothed) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            HStack {
                Text(source.title).font(.headline)
                Text(source.subtitle).foregroundStyle(.secondary)
            }
        }
    }
}

struct ScreenBlock: View {
    let r: ScreenResult
    let now: Int64
    let smoothed: Bool

    private static let colors: [Color] = [.red, .green, .orange, .purple]
    private static let labels = ["0", "1", "2", "3+"]

    var body: some View {
        let age = Double(now - r.updatedAt) / 1e9
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(r.name) · \(f0(r.refreshHz)) Гц").font(.subheadline.weight(.semibold))
                Spacer()
                Text(age < 1 ? "сейчас" : "\(f0(age)) с назад").font(.caption).foregroundStyle(.secondary)
            }
            Text("События курсора: \(f0(r.eventHz)) Гц · кадров в замере: \(r.frames)")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Обновлений курсора за кадр").font(.callout)
                GeometryReader { g in
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { i in
                            Rectangle().fill(Self.colors[i]).frame(width: g.size.width * r.hist[i])
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 4) {
                            Circle().fill(Self.colors[i]).frame(width: 8, height: 8)
                            Text("\(Self.labels[i]): \(pct(r.hist[i]))").font(.caption)
                        }
                    }
                }
            }
            Text("Неровность шага: \(pct(r.unevenMedian)) (в худших 5% кадров: \(pct(r.unevenP95)))")
            Text("Кадров без движения: \(pct(r.stallShare)) · двойных скачков: \(pct(r.jumpShare))")
                .foregroundStyle(.secondary)
            if !smoothed {
                Text("Черновой прогноз со сглаживанием: неровность \(pct(r.smoothUnevenMedian)) (худшие 5%: \(pct(r.smoothUnevenP95))), задержка +\(f1(r.addedLatencyMs)) мс")
                    .foregroundStyle(.blue)
            }
            Text("Событие доходит до программы за \(f2(r.tapLatencyMedianMs)) мс (худший 1%: \(f2(r.tapLatencyP99Ms)) мс)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SmoothingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let st = model.smoother
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Сглаживать движение курсора", isOn: $model.smoothingEnabled)
                    .toggleStyle(.switch)
                Picker("Режим", selection: $model.mode) {
                    ForEach(SmoothingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.smoothingEnabled)
                Text(modeLine(st))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Трекпад", selection: $model.trackpad) {
                    ForEach(TrackpadPolicy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 380)
                .disabled(!model.smoothingEnabled)
                Label(stateText(st), systemImage: stateIcon(st))
                    .foregroundStyle(stateColor(st))
                if model.enlargements.total > 0 {
                    Text("Курсор увеличивался за 2 минуты: \(model.enlargements.total) раз, из них при сглаживании: \(model.enlargements.whileSmoothing)")
                        .font(.caption).foregroundStyle(.orange)
                }
                if st.state == .smoothing || st.state == .waiting {
                    Text("Перехват: \(f2(st.tapLatencyMs.median)) мс (худший 1%: \(f2(st.tapLatencyMs.p99)) мс) · вывод кадра: точность \(f2(st.wakeErrorMs.median)) мс (худший 1%: \(f2(st.wakeErrorMs.p99)) мс)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if st.state == .failed {
                    Button("Попробовать снова") { Smoother.shared.retry() }
                }
                if st.state == .noAccess {
                    Text("Нужно разрешение «Универсальный доступ» для PointerSync. После включения перезапустите приложение.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Открыть настройки") { model.openPrivacySettings("Privacy_Accessibility") }
                        Button("Перезапустить") { model.relaunch() }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Сглаживание").font(.headline)
        }
    }

    private func modeLine(_ st: SmootherStatus) -> String {
        let period = st.periodMs > 0 ? st.periodMs * 1e6 : 7.5e6
        let added = model.mode.addedLatencyMs(period: period)
        let sign = added >= 0 ? "+" : "−"
        if model.mode == .smooth { return "\(model.mode.note) Задержка к macOS: +\(f1(added)) мс." }
        let slow = SmoothingMode.smooth.addedLatencyMs(period: period)
        return "\(model.mode.note) Задержка к macOS на быстрых движениях: \(sign)\(f1(abs(added))) мс; на медленных +\(f1(slow)) мс, это меньше точки."
    }

    private func stateText(_ st: SmootherStatus) -> String {
        switch st.state {
        case .starting: return "Запускаюсь…"
        case .off: return "Выключено"
        case .waiting: return "Готово, жду движения"
        case .smoothing: return "Сглаживаю: \(st.source) на \(st.display) (\(st.refreshHz) Гц)"
        case .gameMode: return "Пауза: включён игровой режим"
        case .noAccess: return "Нет доступа к перехвату событий"
        case .failed: return "Остановлено: \(st.problem)"
        }
    }

    private func stateIcon(_ st: SmootherStatus) -> String {
        switch st.state {
        case .smoothing, .waiting: return "checkmark.circle.fill"
        case .off, .starting, .gameMode: return "pause.circle.fill"
        case .noAccess, .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func stateColor(_ st: SmootherStatus) -> Color {
        switch st.state {
        case .smoothing, .waiting: return .green
        case .off, .starting, .gameMode: return .secondary
        case .noAccess, .failed: return .orange
        }
    }
}

struct RateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let source = model.selectedRateSource {
                    if model.rateSources.count > 1 {
                        Picker("Устройство", selection: $model.rateSourceID) {
                            ForEach(model.rateSources) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text("\(source.name): \(source.detail)").font(.callout)
                    ForEach(source.screens) { RateScreenView(screen: $0, model: model) }
                    if let message = model.rateMessage {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                    Text(model.smoothingEnabled
                         ? "Это совет для работы без сглаживания: со сглаживанием курсор и так обновляется каждый кадр."
                         : "Задержка от смены частоты не меняется. Оценка по твоим отчётам за последние 2 минуты.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Подвигайте мышью 10–20 секунд: программа запишет, как часто она присылает отчёты, и подберёт частоту экрана.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Частота экрана").font(.headline)
        }
    }
}

struct RateScreenView: View {
    let screen: RateScreen
    @ObservedObject var model: AppModel

    var body: some View {
        let best = screen.options.first { $0.hz == screen.best }
        let current = screen.options.first { $0.current }
        VStack(alignment: .leading, spacing: 8) {
            Text("\(screen.name) · сейчас \(f0(screen.currentHz)) Гц").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("Частота")
                    Text("Неровность")
                    Text("Курсор стоит")
                    Text("Двойной шаг")
                    Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(screen.options) { o in
                    GridRow {
                        HStack(spacing: 6) {
                            Text("\(f0(o.hz)) Гц").fontWeight(o.hz == screen.best ? .semibold : .regular)
                            if o.hz == screen.best {
                                Text("лучше всего")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green.opacity(0.18)))
                            }
                        }
                        Text(pct(o.uneven)).monospacedDigit()
                        Text(pct(o.empty)).monospacedDigit()
                        Text(pct(o.doubles)).monospacedDigit()
                        if o.current {
                            Text("сейчас").foregroundStyle(.secondary)
                        } else {
                            Button("Включить") { model.switchRate(screen.id, o.hz) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            if let best, !best.current {
                Text(current.map { "С \(f0(best.hz)) Гц курсор пойдёт ровнее: неровность \(pct(best.uneven)) вместо \(pct($0.uneven))." }
                     ?? "Для этого устройства лучше всего \(f0(best.hz)) Гц.")
                    .font(.callout)
            } else if best != nil {
                Text("Уже стоит лучшая частота для этого устройства.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
