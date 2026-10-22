import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = SetupModel()
    var window: NSWindow!
    private var languageWatch: AnyCancellable?
    private var coachWatch: AnyCancellable?
    private let howTo = HowToPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // The menu speaks the chosen language too.
        languageWatch = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.buildMenu() }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "PointerSync"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        // The SwiftUI view sits in a plain one, so a picture of the window can lie over it while
        // the look changes.
        let host = NSHostingView(rootView: RootView(model: model))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 660))
        container.wantsLayer = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.center()
        if CommandLine.arguments.contains("--preview") {
            // A picture to look at, nothing more: it takes no focus, keys or clicks.
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        // Everything that moves follows the screen's own frames, at its full rate.
        FrameClock.shared.attach(to: host)
        FrameClock.shared.onFrame = { [model] in
            CursorTrail.shared.step(now: FrameClock.shared.now)
            model.frame()
        }
        Settings.shared.appearanceTransition = { [weak self] apply in
            if let self { self.ripple(apply) } else { apply() }
        }
        // How to move the mouse, beside the window, while a test waits for a moving hand.
        coachWatch = model.$coach.combineLatest(model.$panel, model.$stage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coach, panel, stage in
                guard let self else { return }
                self.howTo.show(coach != nil && panel == nil && stage == .measure, model: self.model, beside: self.window)
            }

        Settings.shared.applyAppearance()
        let args = CommandLine.arguments
        if args.contains("--preview") { Settings.shared.persist = false }
        if let i = args.firstIndex(of: "--glass"), i + 1 < args.count {
            Settings.shared.glass = args[i + 1] != "off"
        }
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "light" ? .aqua : .darkAqua)
        }
        if let i = args.firstIndex(of: "--language"), i + 1 < args.count {
            Settings.shared.language = Language(rawValue: args[i + 1]) ?? .system
        }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            let stage = args[i + 1]
            DispatchQueue.main.async { [model] in model.preview(stage) }   // after any settings echo
        }
        // `--then language|theme|glass`: a second in, change that, to see how it moves.
        if let i = args.firstIndex(of: "--then"), i + 1 < args.count {
            let change = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let settings = Settings.shared
                withAnimation(.smooth(duration: 0.4)) {
                    switch change {
                    case "language": settings.language = settings.russian ? .en : .ru
                    case "theme": settings.appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .light : .dark
                    default: settings.glass.toggle()
                    }
                }
            }
        }
    }

    /// Light to dark and back as a ripple: the new paper floods the window in a circle growing
    /// out of the pointer, the look changes under it, and the paper lifts off the new one.
    private func ripple(_ change: @escaping () -> Void) {
        guard window.isVisible, let container = window.contentView, let layer = container.layer else { change(); return }
        let bounds = container.bounds
        let mouse = container.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let from = bounds.contains(mouse) ? mouse : CGPoint(x: bounds.midX, y: bounds.midY)
        let reach = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                     CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            .map { hypot($0.x - from.x, $0.y - from.y) }.max() ?? 1000
        func circle(_ r: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: from.x - r, y: from.y - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        let flood = CAShapeLayer()
        flood.frame = bounds
        flood.fillColor = Theme.paper(dark: Settings.shared.goesDark)
        flood.path = circle(reach)
        layer.addSublayer(flood)
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = circle(1)
        grow.toValue = circle(reach)
        grow.duration = 0.42
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.25, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                change()
                // One frame for the new look to draw under the paper, then lift it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    CATransaction.begin()
                    CATransaction.setCompletionBlock { flood.removeFromSuperlayer() }
                    let lift = CABasicAnimation(keyPath: "opacity")
                    lift.fromValue = 1
                    lift.toValue = 0
                    lift.duration = 0.34
                    flood.opacity = 0
                    flood.add(lift, forKey: "lift")
                    CATransaction.commit()
                }
            }
        }
        flood.add(grow, forKey: "grow")
        CATransaction.commit()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let view = window.contentView { FrameClock.shared.attach(to: view) }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        howTo.show(false, model: model, beside: window)
    }

    /// The close button asks first, like quitting does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.quitConfirmed { return true }
        model.askToQuit()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.quitConfirmed else {
            model.askToQuit()
            return .terminateCancel
        }
        model.cleanUpBeforeQuit()
        return .terminateNow
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: tr("Подбирает частоту экрана под мышь, чтобы курсор шёл ровно.",
                                                    "Matches your display's refresh rate to your mouse, so the cursor moves evenly."),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func showSettings() { model.panel = .settings }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: tr("О программе PointerSync", "About PointerSync"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: tr("Настройки…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Скрыть PointerSync", "Hide PointerSync"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Выйти из PointerSync", "Quit PointerSync"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: tr("Окно", "Window"))
        windowMenu.addItem(withTitle: tr("Закрыть", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: tr("Свернуть", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(CommandLine.arguments.contains("--preview") ? .accessory : .regular)
    app.run()
}
