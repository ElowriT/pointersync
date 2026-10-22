import AppKit
import SwiftUI
import IOKit.hid

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let hid = HIDReader()
    let display = DisplayClock()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccess()
        hid.start()
        EventTap.start()
        display.start()
        CursorScale.start()
        Smoother.shared.start(settings: model.settings)
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PointerSync"
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.start()

        // --record N: save a measurement after N seconds, print it and quit (for scripted runs).
        if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count,
           let seconds = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [model] in
                model.refresh()
                model.save()
                print(model.summaryLines().joined(separator: "\n"))
                print("saved:", model.savedPath ?? "-")
                let st = Smoother.shared.status()
                print("smoother:", st.state, st.problem, "tap latency ms", st.tapLatencyMs, "wake error ms", st.wakeErrorMs)
                fflush(stdout)
                exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { model.save(auto: true) }

    private func requestAccess() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        // Taking motion over needs an active event tap, which needs Accessibility.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        Recorder.shared.updateStatus {
            $0.hidAccess = Int(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)
            $0.listenAccess = CGPreflightListenEventAccess()
        }
    }

    @objc private func saveMeasurement() { model.save() }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Скрыть PointerSync", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из PointerSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "Файл")
        let save = NSMenuItem(title: "Сохранить замер", action: #selector(saveMeasurement), keyEquivalent: "s")
        save.target = self
        fileMenu.addItem(save)
        fileMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = main
    }
}

// --advise FILE: print the refresh-rate advice for a saved recording and quit.
if let i = CommandLine.arguments.firstIndex(of: "--advise"), i + 1 < CommandLine.arguments.count {
    struct Recording: Decodable { var devices: [DeviceInfo]; var values: [HIDValue]; var events: [PointerEvent] }
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let r = try! JSONDecoder().decode(Recording.self, from: data)
    var snap = Snapshot()
    snap.devices = r.devices; snap.values = r.values; snap.events = r.events
    _ = NSApplication.shared
    for source in RateMatcher.advise(snap, now: Clock.now()) {
        print(source.name, "·", source.detail, "· отчётов", source.reports)
        for screen in source.screens {
            print("  \(screen.name), сейчас \(f0(screen.currentHz)) Гц, лучше всего \(screen.best.map(f0) ?? "-") Гц")
            for o in screen.options {
                print("    \(f0(o.hz)) Гц: неровность \(pct(o.uneven)), курсор стоит \(pct(o.empty)), двойной шаг \(pct(o.doubles))\(o.current ? " (сейчас)" : "")")
            }
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
