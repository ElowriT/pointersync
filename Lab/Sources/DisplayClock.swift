import AppKit
import QuartzCore

/// Records the vsync time of every frame on every screen, on its own thread.
final class DisplayClock: NSObject {
    private final class Target: NSObject {
        let displayID: UInt32
        init(_ id: UInt32) { displayID = id }

        @objc func tick(_ link: CADisplayLink) {
            Recorder.shared.add(Frame(d: displayID,
                                      t: Int64(link.timestamp * 1e9),
                                      target: Int64(link.targetTimestamp * 1e9),
                                      r: Clock.now()))
        }
    }

    private var thread: Thread!
    private var links: [CADisplayLink] = []
    private var targets: [Target] = []

    func start() {
        thread = Thread { [weak self] in
            _ = self
            RunLoop.current.add(Port(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "pointersync.display"
        thread.qualityOfService = .userInteractive
        thread.start()
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    @objc private func screensChanged() { rebuild() }

    private func rebuild() {
        links.forEach { $0.invalidate() }
        links = []
        targets = []
        var infos: [DisplayInfo] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let fps = screen.maximumFramesPerSecond
            infos.append(DisplayInfo(id: id,
                                     name: screen.localizedName,
                                     maxFPS: fps,
                                     modeRefresh: CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0,
                                     bounds: CGDisplayBounds(id),
                                     builtIn: CGDisplayIsBuiltin(id) != 0))
            let target = Target(id)
            let link = screen.displayLink(target: target, selector: #selector(Target.tick(_:)))
            // Ask for every frame so the measured clock is the panel's top rate.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
            targets.append(target)
            links.append(link)
            perform(#selector(attach(_:)), on: thread, with: link, waitUntilDone: false)
        }
        Recorder.shared.setDisplays(infos)
    }

    @objc private func attach(_ link: CADisplayLink) {
        link.add(to: .current, forMode: .common)
    }
}
