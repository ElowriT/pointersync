import Foundation
import IOKit
import IOKit.hid

/// Reads raw reports from mice, pointers and digitizers (the trackpad's multitouch
/// interface) on its own thread, before the system applies acceleration or coalescing.
final class HIDReader {
    private var manager: IOHIDManager?
    private var indexByDevice: [UnsafeMutableRawPointer: Int32] = [:]
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var seenRegistryIDs: Set<UInt64> = []

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "pointersync.hid"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDReader>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            let received = Clock.now()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_GenericDesktop) else { return }
            let usage = IOHIDElementGetUsage(element)
            guard usage == UInt32(kHIDUsage_GD_X) || usage == UInt32(kHIDUsage_GD_Y),
                  IOHIDElementIsRelative(element),
                  IOHIDValueGetLength(value) <= 4 else { return }
            let reader = Unmanaged<HIDReader>.fromOpaque(ctx!).takeUnretainedValue()
            let device = IOHIDElementGetDevice(element)
            guard let d = reader.indexByDevice[Unmanaged.passUnretained(device).toOpaque()] else { return }
            Recorder.shared.add(HIDValue(d: d,
                                         t: Clock.ns(fromTicks: IOHIDValueGetTimeStamp(value)),
                                         r: received,
                                         u: usage,
                                         v: Int32(truncatingIfNeeded: IOHIDValueGetIntegerValue(value))))
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        Recorder.shared.updateStatus { $0.hidOpen = result }
        CFRunLoopRun()
    }

    private func added(_ device: IOHIDDevice) {
        let key = Unmanaged.passUnretained(device).toOpaque()
        guard indexByDevice[key] == nil else { return }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        // A device that matches several usage pairs comes in once per pair.
        guard seenRegistryIDs.insert(registryID).inserted else { return }
        let index = Int32(reportBuffers.count)
        indexByDevice[key] = index

        func prop<T>(_ k: String) -> T? { IOHIDDeviceGetProperty(device, k as CFString) as? T }
        let maxSize = max(prop(kIOHIDMaxInputReportSizeKey) ?? 64, 1)
        Recorder.shared.addDevice(DeviceInfo(
            index: index,
            name: prop(kIOHIDProductKey) ?? "HID-устройство",
            transport: prop(kIOHIDTransportKey) ?? "?",
            vendorID: prop(kIOHIDVendorIDKey) ?? 0,
            productID: prop(kIOHIDProductIDKey) ?? 0,
            usagePage: prop(kIOHIDPrimaryUsagePageKey) ?? 0,
            usage: prop(kIOHIDPrimaryUsageKey) ?? 0,
            registryID: registryID,
            builtIn: prop(kIOHIDBuiltInKey) ?? false,
            maxInputReportSize: maxSize))

        // Every report, motion or not: the trackpad's multitouch frames carry no X/Y values.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        reportBuffers.append(buffer)
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(device, buffer, maxSize, { ctx, _, _, _, _, _, length, timestamp in
            let received = Clock.now()
            Recorder.shared.add(HIDReport(d: Int32(Int(bitPattern: ctx) - 1),
                                          t: Clock.ns(fromTicks: timestamp),
                                          r: received,
                                          len: Int32(length)))
        }, UnsafeMutableRawPointer(bitPattern: Int(index) + 1))
    }
}
