import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        ZStack(alignment: .top) {
            Theme.paper.ignoresSafeArea()
            stage
                .id(model.stage == .folding ? "result" : "\(model.stage)")
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                .padding(.horizontal, 32)
                .padding(.top, 62)
                .padding(.bottom, 24)
                .disabled(model.panel != nil)   // no clicks or Return reach it under a panel
            if let panel = model.panel {
                if panel == .quit {
                    Theme.paper.opacity(0.8)
                        .ignoresSafeArea()
                        .onTapGesture { model.panel = nil }
                        .transition(.opacity)
                    QuitDialog(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                } else {
                    PanelSheet(model: model, panel: panel)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            Header(model: model)
        }
        .frame(width: 440, height: 660)
        .animation(.easeInOut(duration: 0.35), value: model.stage)
        .animation(.easeInOut(duration: 0.28), value: model.panel)
    }

    @ViewBuilder private var stage: some View {
        switch model.stage {
        case .welcome: WelcomeView(model: model)
        case .measure: MeasureView(model: model)
        case .result, .folding: ResultView(model: model)
        case .confirm: ConfirmView(model: model)
        case .done: DoneView(model: model)
        }
    }
}

/// The name in the title bar, with the one color as its dot, and what fits beside it.
struct Header: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        ZStack {
            HStack(spacing: 7) {
                Circle().fill(Theme.signal).frame(width: 6, height: 6)
                Text("POINTERSYNC")
                    .font(Theme.mono(11))
                    .tracking(2.4)
                    .foregroundStyle(Theme.ink)
            }
            HStack(spacing: 0) {
                Spacer()
                trailing
            }
        }
        .frame(height: 28)
        .padding(.top, 2)
        .padding(.horizontal, 12)
        .ignoresSafeArea(edges: .top)   // level with the window's buttons
    }

    @ViewBuilder private var trailing: some View {
        if model.panel == nil {
            if model.stage == .measure {
                if model.recheck.isEmpty && model.testCount > 0 {
                    Caption(text: "\(model.testNumber) / \(model.testCount)").padding(.trailing, 8)
                }
            } else if [.welcome, .result, .done].contains(model.stage) {
                HStack(spacing: settings.glass ? 6 : 0) {
                    IconAction(symbol: "info", label: tr("Как это работает", "How it works")) { model.panel = .about }
                    IconAction(symbol: "gearshape", label: tr("Настройки", "Settings")) { model.panel = .settings }
                }
            }
        }
    }
}

// MARK: - Letters that flip

/// A letter on a split-flap board, or a whole line on a big flap: the old one tips away
/// over its middle, then the new one falls into place.
private struct Flap: ViewModifier {
    var angle: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.55)
            .opacity(abs(angle) >= 90 ? 0 : 1)
    }
}

extension AnyTransition {
    static func flap(after delay: Double = 0) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Flap(angle: -90), identity: Flap(angle: 0))
                .animation(.easeOut(duration: 0.14).delay(delay + 0.1)),
            removal: .modifier(active: Flap(angle: 90), identity: Flap(angle: 0))
                .animation(.easeIn(duration: 0.1).delay(delay)))
    }
}

/// Mono capitals, each in its own cell, that flip over one by one, left to right, whenever
/// the words change: a new language, the next rate, a new hint.
struct FlapText: View {
    var text: String
    var size: CGFloat
    var tracking: CGFloat
    var color: Color

    var body: some View {
        let letters = Array(text)
        HStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { i in
                ZStack {
                    Text(String(letters[i]))
                        .font(Theme.mono(size))
                        .foregroundStyle(color)
                        .id(letters[i])
                        .transition(.flap(after: Double(i) * 0.016))
                }
                .frame(width: size * 0.6 + tracking, alignment: .leading)
                .transition(.flap(after: Double(i) * 0.016))
            }
        }
        .fixedSize()
        .animation(.linear(duration: 0.3), value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Proportional text that flips over as a whole when it changes.
struct FlipLine: View {
    var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .id(text)
                .transition(.flap())
        }
        .animation(.linear(duration: 0.3), value: text)
    }
}

// MARK: - Pieces

/// A small mono caption, all capitals, in flipping letters.
struct Caption: View {
    var text: String
    var color: Color = Theme.quiet
    var size: CGFloat = 11

    var body: some View {
        FlapText(text: text.uppercased(), size: size, tracking: size * 0.12, color: color)
    }
}

/// The one strong button: a solid ink capsule. It stays solid with glass on, since system
/// glass buttons fade to grey when the window is in the background.
struct InkButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { FlipLine(text: title) }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.defaultAction)
    }
}

struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.paper)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Theme.ink))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A word in mono capitals that darkens under the pointer.
struct TextAction: View {
    var title: String
    var shortcut: KeyboardShortcut?
    var action: () -> Void
    @State private var hover = false

    init(title: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Caption(text: title, color: hover ? Theme.ink : Theme.quiet)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A small symbol button: a glass circle with glass on, a bare symbol without.
struct IconAction: View {
    var symbol: String
    var label: String
    var action: () -> Void
    @ObservedObject private var settings = Settings.shared
    @State private var hover = false

    var body: some View {
        ZStack {
            if settings.glass {
                Button(action: action) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button(action: action) {
                    Image(systemName: symbol == "info" ? "info.circle" : symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(hover ? Theme.ink : Theme.quiet)
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .transition(.opacity)
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Choices as a row of mono words. The chosen one sits on a glass capsule, or over an ink
/// line without glass, and either one flows over to the next choice like a drop: its front
/// edge runs ahead and the back edge catches up.
struct WordPicker<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    @ObservedObject private var settings = Settings.shared
    @State private var frames: [Int: CGRect] = [:]
    @State private var left: CGFloat = 0
    @State private var right: CGFloat = 0

    private var chosen: Int? { options.firstIndex { $0.value == selection } }

    var body: some View {
        let glass = settings.glass
        HStack(spacing: glass ? 4 : 20) {
            ForEach(options.indices, id: \.self) { i in
                Button { withAnimation(.smooth(duration: 0.4)) { selection = options[i].value } } label: {
                    Caption(text: options[i].title, color: i == chosen ? Theme.ink : Theme.quiet)
                        .padding(.horizontal, glass ? 12 : 0)
                        .padding(.vertical, glass ? 7 : 0)
                        .padding(.bottom, glass ? 0 : 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(GeometryReader { g in
                    Color.clear.preference(key: OptionFrames.self, value: [i: g.frame(in: .named("picker"))])
                })
            }
        }
        .background(alignment: .topLeading) {
            if glass, let f = chosen.flatMap({ frames[$0] }) {
                Color.clear
                    .glassEffect(.regular, in: Capsule())
                    .frame(width: max(0, right - left), height: f.height)
                    .offset(x: left, y: f.minY)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if !glass, let f = chosen.flatMap({ frames[$0] }) {
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: max(0, right - left), height: 1.5)
                    .offset(x: left, y: f.maxY - 1.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .coordinateSpace(.named("picker"))
        .padding(.leading, glass ? -12 : 0)   // the first word lines up with the text above
        .onPreferenceChange(OptionFrames.self) { new in
            frames = new
            // Words got wider or narrower (a new language, glass on or off): follow them.
            if let i = chosen, let f = new[i], abs(f.minX - left) > 0.5 || abs(f.maxX - right) > 0.5 {
                withAnimation(.smooth(duration: 0.3)) { left = f.minX; right = f.maxX }
            }
        }
        .onChange(of: chosen) { old, new in glide(from: old, to: new) }
    }

    private func glide(from old: Int?, to new: Int?) {
        guard let new, let f = frames[new] else { return }
        let ahead = Animation.spring(response: 0.28, dampingFraction: 0.78)
        let behind = Animation.spring(response: 0.46, dampingFraction: 0.74)
        let rightward = (old ?? new) < new
        withAnimation(rightward ? ahead : behind) { right = f.maxX }
        withAnimation(rightward ? behind : ahead) { left = f.minX }
    }
}

private struct OptionFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

struct BodyText: View {
    var text: String

    var body: some View {
        FlipLine(text: text)
            .font(Theme.body)
            .foregroundStyle(Theme.quiet)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Title: View {
    var text: String

    var body: some View {
        FlipLine(text: text)
            .font(Theme.title)
            .tracking(-0.9)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one ask for money, at the end, when the app has done its job: a card that opens the
/// tip jar. On glass with glass on, outlined without.
struct CoffeeCard: View {
    var url: URL
    @ObservedObject private var settings = Settings.shared
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 14) {
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    FlipLine(text: tr("Угостить кофе", "Buy me a coffee"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    FlipLine(text: tr("PointerSync бесплатный. Если помог — спасибо можно сказать на Ko-fi.",
                                      "PointerSync is free. If it helped, you can say thanks on Ko-fi."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Theme.ink : Theme.quiet)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .modifier(CardLook(glass: settings.glass, shape: shape))
        .help("ko-fi.com")
    }
}

private struct CardLook<S: InsettableShape>: ViewModifier {
    var glass: Bool
    var shape: S

    func body(content: Content) -> some View {
        if glass {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Stages
//
// Each stage watches the settings too, so a new language reaches every word and flips it.

struct WelcomeView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Dial(mode: .idle)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 28)
            Title(text: tr("Мышь и экран\nв одном ритме.", "Mouse and display,\nin step."))
            BodyText(text: tr("Проверю каждую частоту экрана с твоей мышью и покажу, где курсор идёт ровнее всего. Полминуты — и можно забыть.",
                              "Tries every refresh rate of your display with your mouse and shows where the cursor moves most evenly. Half a minute, then forget about it."))
                .padding(.top, 12)
            if let notice = model.notice {
                FlipLine(text: notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            Spacer(minLength: 28)
            InkButton(title: tr("Начать", "Start")) { model.startMeasuring() }
        }
    }
}

struct MeasureView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Dial(mode: .measure, progress: model.progress, live: model.live, liveHz: model.liveHz,
                 switching: model.hint == .switching)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 28)
            Caption(text: phase)
            Text(model.testingHz.map(hz) ?? " ")
                .font(.system(size: 44, weight: .light))
                .tracking(-1.4)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: model.testingHz ?? 0))
                .animation(.snappy, value: model.testingHz)
                .padding(.top, 2)
            BodyText(text: tr("Води мышью большими быстрыми кругами, без остановок. При смене частоты экран мигнёт — так и нужно.",
                              "Move your mouse in big, quick circles without stopping. The display blinks as the rate changes — that's expected."))
                .padding(.top, 6)
            Spacer(minLength: 24)
            Hairline()
            HStack(spacing: 16) {
                Caption(text: String(model.deviceTitle(genitive: false).prefix(22)))
                Spacer(minLength: 0)
                Caption(text: hint, color: model.hint == .slow ? Theme.signal : Theme.quiet)
            }
            .padding(.top, 12)
            HStack {
                TextAction(title: tr("Остановить тест", "Stop the test"), shortcut: .cancelAction) { model.stopMeasuring() }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private var phase: String {
        if model.hint == .switching { return tr("Переключаю на", "Switching to") }
        if !model.recheck.isEmpty { return tr("Ещё раз", "Once more") }
        return tr("Проверяю", "Trying")
    }

    private var hint: String {
        switch model.hint {
        case .start: return tr("Начни водить", "Start moving")
        case .slow: return tr("Быстрее", "Faster")
        case .switching: return tr("Продолжай водить", "Keep moving")
        case .moving:
            guard model.recheck.count == 2 else { return tr("Так держать", "Keep going") }
            let a = f0(model.recheck[0]), b = f0(model.recheck[1])
            return tr("\(a) и \(b) почти равны", "\(a) and \(b) are close")
        }
    }
}

struct ResultView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        if let picked = model.trial(model.selected), !model.measuredTrials.isEmpty {
            content(picked)
        } else {
            failed
        }
    }

    private func content(_ picked: RateTrial) -> some View {
        let keeps = abs(picked.hz - model.originalHz) < 0.5
        let best = picked.hz == model.recommended
        let recommended = model.recommended.map(hz) ?? "—"
        return VStack(alignment: .leading, spacing: 0) {
            Caption(text: best ? tr("Лучше всего", "Best") : tr("Твой выбор", "Your pick"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(f0(picked.hz))
                    .font(.system(size: 104, weight: .ultraLight))
                    .tracking(-4)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: picked.hz))
                FlipLine(text: tr("Гц", "Hz"))
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.quiet)
            }
            .foregroundStyle(Theme.ink)
            .animation(.snappy, value: picked.hz)
            .padding(.leading, -9)   // the thin 1's own margin, so it lines up with the text
            .padding(.top, -8)
            .padding(.bottom, -6)
            BodyText(text: best ? tr("Для \(model.forWhat).", "For \(model.forWhat).") + model.againNote
                                : tr("По замеру лучше всего \(recommended).", "The test liked \(recommended) best."))
            Spacer(minLength: 20)
            RateTable(trials: Array(model.measuredTrials.reversed()), selected: model.selected, recommended: model.recommended,
                      original: model.originalHz, previous: model.previous) { model.selected = $0 }
                .opacity(model.stage == .folding ? 0.35 : 1)
            if let notice = model.notice {
                FlipLine(text: notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Spacer(minLength: 20)
            InkButton(title: keeps ? tr("Оставить \(hz(picked.hz))", "Keep \(hz(picked.hz))")
                                   : tr("Включить \(hz(picked.hz))", "Switch to \(hz(picked.hz))")) { model.apply() }
                .disabled(model.stage == .folding)
            HStack {
                TextAction(title: tr("Проверить ещё раз", "Test again")) { model.startMeasuring() }
                Spacer()
                TextAction(title: tr("Не сейчас", "Not now")) { model.askToQuit() }
            }
            .padding(.top, 4)
            .disabled(model.stage == .folding)
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Dial(mode: .countdown, progress: 0)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 28)
            Title(text: tr("Не получилось.", "That didn't work."))
            BodyText(text: tr("Мыши было слишком мало: нужно водить быстрее и дольше. Частота экрана не менялась.",
                              "There wasn't enough quick mouse movement. The display's rate is unchanged."))
                .padding(.top, 12)
            Spacer(minLength: 28)
            InkButton(title: tr("Попробовать ещё раз", "Try again")) { model.startMeasuring() }
            HStack {
                Spacer()
                TextAction(title: tr("Выйти", "Quit")) { model.askToQuit() }
            }
            .padding(.top, 4)
        }
    }
}

struct ConfirmView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let left = Int(model.countdown.rounded(.up))
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Dial(mode: .countdown, progress: model.countdown / SetupModel.confirmSeconds)
                VStack(spacing: 0) {
                    Text("\(left)")
                        .font(.system(size: 64, weight: .ultraLight))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: left)
                    Caption(text: tr(ruPlural(left, "секунда", "секунды", "секунд"), left == 1 ? "second" : "seconds"), size: 9.5)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 28)
            Title(text: tr("Как теперь?", "How's that?"))
            BodyText(text: tr("Поводи курсором. Если ничего не нажимать, через \(Int(SetupModel.confirmSeconds)) секунд всё вернётся как было.",
                              "Move the cursor around. If you don't press anything, it all goes back in \(Int(SetupModel.confirmSeconds)) seconds."))
                .padding(.top, 12)
            Spacer(minLength: 28)
            InkButton(title: tr("Оставить \(model.selected.map(hz) ?? "")", "Keep \(model.selected.map(hz) ?? "")")) { model.keep() }
            HStack {
                TextAction(title: tr("Вернуть \(hz(model.originalHz))", "Go back to \(hz(model.originalHz))")) { model.revert() }
                Spacer()
            }
            .padding(.top, 4)
        }
    }
}

struct DoneView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared
    @State private var drawn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Dial(mode: .done, progress: 1)
                .overlay(
                    CheckMark()
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 44, height: 32)
                )
                .frame(maxWidth: .infinity)
                .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.25)) { drawn = true } }
            Spacer(minLength: 28)
            Title(text: tr("Готово.", "Done."))
            BodyText(text: model.doneMessage)
                .padding(.top, 12)
            Spacer(minLength: 24)
            if let coffee = AppInfo.coffee {
                CoffeeCard(url: coffee)
                    .padding(.bottom, 14)
            }
            InkButton(title: tr("Закрыть", "Close")) { model.confirmQuit() }
            HStack {
                TextAction(title: tr("Проверить ещё раз", "Test again")) { model.startMeasuring() }
                Spacer()
            }
            .padding(.top, 4)
        }
    }
}
