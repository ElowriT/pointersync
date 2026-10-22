import AppKit
import IOKit

@_silgen_name("CGEventGetIntegerValueField")
private func rawIntegerField(_ event: CGEvent, _ field: UInt32) -> Int64

/// Names the device that moves the pointer, from the events macOS delivers to apps.
///
/// Over this app's window the events come to a local monitor, over anything else to a
/// global one; neither needs a permission for mouse events. Devices are told apart by the
/// service that sent the event (field 87), not by the event's subtype: Magic Mouse marks
/// its events like a trackpad does. The events' times are no use for timing the device:
/// macOS hands them to apps already lined up with the screen's frames.
final class DeviceWatcher {
    struct Device {
        var name: String
        var transport: String
        var trackpad: Bool
        var events = 0
    }

    private(set) var devices: [Int64: Device] = [:]
    private var monitors: [Any] = []

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.record(event)
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.record(event)
        }) { monitors.append(global) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func reset() { devices = [:] }

    /// The device that moved the most.
    var main: Device? { devices.values.max { $0.events < $1.events } }

    private func record(_ event: NSEvent) {
        guard let cg = event.cgEvent else { return }
        let sender = rawIntegerField(cg, 87)
        guard sender != 0 else { return }   // posted by software, not a device
        var device = devices[sender] ?? Self.describe(sender)
        device.events += 1
        devices[sender] = device
    }

    /// Name, connection and kind of the device behind a registry ID.
    private static func describe(_ id: Int64) -> Device {
        guard let match = IORegistryEntryIDMatching(UInt64(id)) else { return Device(name: "", transport: "", trackpad: false) }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return Device(name: "", transport: "", trackpad: false) }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        var cls = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(service, &cls)
        let name = prop("Product") ?? ""
        let transport: String
        switch prop("Transport") ?? "" {
        case "Bluetooth Low Energy", "Bluetooth": transport = "Bluetooth"
        case "USB": transport = "USB"
        default: transport = ""
        }
        let trackpad = (name + String(cString: cls)).localizedCaseInsensitiveContains("trackpad")
        return Device(name: name, transport: transport, trackpad: trackpad)
    }
}
