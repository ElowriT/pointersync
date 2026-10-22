import AppKit
import SwiftUI

/// Settings or "how it works", as a page of its own over the window.
struct PanelSheet: View {
    @ObservedObject var model: SetupModel
    var panel: SetupModel.Panel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                FlipLine(text: panel == .settings ? tr("Настройки", "Settings") : tr("Как это работает", "How it works"))
                    .font(.system(size: 24, weight: .medium))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                Spacer()
                TextAction(title: tr("Готово", "Done"), shortcut: .cancelAction) { model.panel = nil }
            }
            .padding(.bottom, 12)
            if panel == .settings {
                SettingsPanel()
            } else {
                ScrollView {
                    AboutPanel()
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            Spacer(minLength: 0)
            Caption(text: "PointerSync \(AppInfo.version) · \(AppInfo.copyright)", size: 9.5)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 32)
        .padding(.top, 58)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
    }
}

struct SettingsPanel: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(tr("Тема", "Appearance")) {
                WordPicker(options: [(Appearance.system, tr("Система", "System")), (.light, tr("Светлая", "Light")), (.dark, tr("Тёмная", "Dark"))],
                           selection: $settings.appearance)
            }
            row(tr("Стекло", "Glass"), note: tr("Пробное: стекло macOS на кнопках, переключателях и выбранной частоте.",
                                                "On trial: macOS's own glass on buttons, switches and the rate you pick.")) {
                WordPicker(options: [(true, tr("Вкл", "On")), (false, tr("Выкл", "Off"))], selection: $settings.glass)
            }
            row(tr("Что важнее", "What matters more"), note: settings.priority.note) {
                WordPicker(options: [(Priority.cursor, tr("Курсор", "Cursor")), (.balance, tr("Баланс", "Balance")), (.frames, tr("Кадры", "Frames"))],
                           selection: $settings.priority)
            }
            row(tr("Язык", "Language")) {
                WordPicker(options: [(Language.system, tr("Система", "System")), (.ru, "Русский"), (.en, "English")],
                           selection: $settings.language)
            }
            Hairline()
            FlipLine(text: tr("Проверяется экран, на котором открыто это окно. Чтобы настроить другой, перетащи окно туда.",
                              "The display this window is on gets tested. To tune another one, drag the window there."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }

    private func row<Content: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: title, size: 10)
            content()
            if let note {
                FlipLine(text: note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }
}

struct AboutPanel: View {
    @ObservedObject private var settings = Settings.shared
    /// A steady 133 Hz mouse, like one on Bluetooth, for the two example lanes.
    private static let demo: [Double] = (0..<600).map { i in Double(i) * 7.5 + 0.25 * sin(Double(i) * 1.7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            paragraph(tr("Мышь сообщает компьютеру, куда сдвинулась, много раз в секунду, и у каждой мыши своя частота. Экран обновляет картинку со своей: 60, 120, 165 раз в секунду.",
                         "Your mouse tells the computer where it moved many times a second, and every mouse has its own rate. The display redraws at its own rate: 60, 120, 165 times a second."))
            lane(tr("Мышь 133 Гц, экран 165 Гц: не в такт", "Mouse 133 Hz, display 165 Hz: out of step"), hz: 165)
            paragraph(tr("Когда частоты не совпадают, в одних кадрах курсор стоит, а в других прыгает сразу на два шага. Глаз видит это как рывки, хотя рука движется плавно.",
                         "When the two don't line up, the cursor stands still in some frames and jumps two steps in others. You see stutter, even though your hand moves smoothly."))
            lane(tr("Та же мышь, экран 120 Гц: в такт", "Same mouse, display 120 Hz: in step"), hz: 120)
            paragraph(tr("PointerSync по очереди включает каждую частоту экрана, пока ты водишь мышью, и смотрит, где курсор оказывается в каждом кадре. Если две лучшие частоты почти равны, проверяет их ещё раз. Потом показывает, на какой частоте курсор идёт ровнее всего, а выбор остаётся за тобой. Между мышью и курсором ничего не встаёт, в фоне ничего не работает: меняется только настройка экрана, и вернуть её можно в любой момент в Системных настройках → Дисплеи.",
                         "PointerSync switches your display through each refresh rate while you move the mouse, and looks at where the cursor lands in every frame. If the best two are nearly tied, it tries them again. Then it shows at which rate the cursor moves most evenly, and you choose. Nothing sits between your mouse and the cursor and nothing runs in the background: only a display setting changes, and you can change it back anytime in System Settings → Displays."))
            FlipLine(text: tr("Точки — сигналы мыши, полоски — кадры, пунктир — кадр без движения. Всё замедлено в 28 раз.",
                              "Dots are mouse reports, bars are frames, a dashed bar is a frame with no movement. Slowed down 28 times."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func paragraph(_ text: String) -> some View {
        FlipLine(text: text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink.opacity(0.85))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lane(_ title: String, hz rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(text: title)
            RhythmLane(reports: Self.demo, hz: rate)
                .frame(height: 40)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// "Quit PointerSync?" with what quitting now would leave behind: a card, or glass.
struct QuitDialog: View {
    @ObservedObject var model: SetupModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let content = VStack(alignment: .leading, spacing: 0) {
            FlipLine(text: tr("Выйти из PointerSync?", "Quit PointerSync?"))
                .font(.system(size: 20, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
            FlipLine(text: model.quitConsequence)
                .font(.system(size: 13))
                .foregroundStyle(Theme.quiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            InkButton(title: tr("Выйти", "Quit")) { model.confirmQuit() }
                .padding(.top, 22)
            HStack {
                Spacer()
                TextAction(title: tr("Остаться", "Stay"), shortcut: .cancelAction) { model.panel = nil }
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
        if settings.glass {
            content
                .glassEffect(.regular, in: shape)
                .glassEffectTransition(.materialize)
        } else {
            content
                .background(Theme.paper, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 10)
        }
    }
}
