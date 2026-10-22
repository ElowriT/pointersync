import AppKit
import SwiftUI

/// What to favor when the cursor's evenness and the screen's frame count pull apart.
enum Priority: String, CaseIterable, Identifiable {
    case cursor, balance, frames
    var id: String { rawValue }

    /// How much a lower refresh rate costs, against the cursor's unevenness.
    var frameWeight: Double {
        switch self {
        case .cursor: return 0
        case .balance: return 0.05
        case .frames: return 0.15
        }
    }

    @MainActor
    var note: String {
        switch self {
        case .cursor: return tr("Частота, где курсор идёт ровнее всего. Из равных — та, где больше кадров.",
                                "The rate where the cursor moves most evenly; among equals, the one with more frames.")
        case .balance: return tr("Курсор почти так же ровный, но и кадрами для всего остального не жертвуем.",
                                 "A nearly as even cursor, without giving up frames for everything else.")
        case .frames: return tr("Как можно больше кадров, пока курсор от этого почти не теряет в ровности.",
                                "As many frames as possible, as long as the cursor stays nearly as even.")
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var priority: Priority { didSet { save() } }
    @Published var language: Language { didSet { save() } }
    @Published var appearance: Appearance {
        didSet {
            save()
            if let transition = appearanceTransition { transition { self.applyAppearance() } } else { applyAppearance() }
        }
    }
    /// Wraps a change between light and dark, so the window can animate it; it applies the
    /// change when it is ready to.
    var appearanceTransition: ((@escaping () -> Void) -> Void)?

    /// Whether the app will be dark once `appearance` applies.
    var goesDark: Bool {
        switch appearance {
        case .light: return false
        case .dark: return true
        case .system: return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
    }
    /// macOS's own Liquid Glass on a few controls. On trial.
    @Published var glass: Bool { didSet { save() } }
    /// Off for `--preview` runs, so a look at the screens never changes the user's choices.
    var persist = true

    private init() {
        let d = UserDefaults.standard
        priority = Priority(rawValue: d.string(forKey: "priority") ?? "") ?? .cursor
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .system
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        glass = d.object(forKey: "glass") as? Bool ?? true
    }

    private func save() {
        guard persist else { return }
        let d = UserDefaults.standard
        d.set(priority.rawValue, forKey: "priority")
        d.set(language.rawValue, forKey: "language")
        d.set(appearance.rawValue, forKey: "appearance")
        d.set(glass, forKey: "glass")
        // Choices between designs and animations that are gone now.
        for key in ["design", "measureStyle", "measureStyle2"] { d.removeObject(forKey: key) }
    }

    /// Light, dark, or whatever the system uses.
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Russian or English: the chosen one, else the system's first preference.
    var russian: Bool {
        switch language {
        case .ru: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        }
    }
}

/// The text in the current language.
@MainActor
func tr(_ ru: String, _ en: String) -> String { Settings.shared.russian ? ru : en }

/// "120 Гц" / "120 Hz".
@MainActor
func hz(_ x: Double) -> String { "\(f0(x)) \(tr("Гц", "Hz"))" }

/// Russian plural form for n: 1 секунда, 2 секунды, 5 секунд.
func ruPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

func f0(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0))) }
func pct(_ x: Double) -> String { (x * 100).formatted(.number.precision(.fractionLength(0))) + "%" }

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    static let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 ElowriT"
    /// The tip jar.
    static let coffee = URL(string: "https://ko-fi.com/elo7151")
}
