import Foundation
import CoreGraphics

@_silgen_name("CGEventGetIntegerValueField")
private func rawIntegerField(_ event: CGEvent, _ field: UInt32) -> Int64

/// Listen-only tap at the HID level: sees every pointer event the system makes,
/// with the cursor location it produced. It never changes or delays events.
enum EventTap {
    fileprivate static var port: CFMachPort?
    fileprivate static var eventCount = 0
    fileprivate static var probing = true

    static func start() {
        let thread = Thread { run() }
        thread.name = "pointersync.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func run() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: tapCallback, userInfo: nil) else {
            Recorder.shared.updateStatus { $0.tapRunning = false }
            return
        }
        port = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Recorder.shared.updateStatus { $0.tapRunning = true }
        CFRunLoopRun()
    }

}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = EventTap.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let received = Clock.now()
    let t = Clock.eventTime(event.timestamp)
    if EventTap.eventCount == 0 {
        Recorder.shared.updateStatus { $0.eventTimestampsInTicks = Clock.eventTimestampsInTicks }
    }
    let location = event.location
    let sub = event.getIntegerValueField(.mouseEventSubtype)
    Recorder.shared.add(PointerEvent(t: t, r: received,
                                     x: Double(location.x), y: Double(location.y),
                                     dx: event.getDoubleValueField(.mouseEventDeltaX),
                                     dy: event.getDoubleValueField(.mouseEventDeltaY),
                                     type: type.rawValue, sub: sub,
                                     f87: rawIntegerField(event, 87),
                                     m: event.getIntegerValueField(.eventSourceUserData) == Smoother.marker))

    // Every 50th event: keep all non-zero fields so we can see which one names the device.
    EventTap.eventCount += 1
    if EventTap.probing && EventTap.eventCount % 50 == 1 {
        var fields: [String: Int64] = [:]
        for f in UInt32(0)..<256 {
            let v = rawIntegerField(event, f)
            if v != 0 { fields[String(f)] = v }
        }
        EventTap.probing = Recorder.shared.addProbe(ProbeSample(t: t, sub: sub, fields: fields))
    }
    return Unmanaged.passUnretained(event)
}
