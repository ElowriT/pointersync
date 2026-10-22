import Foundation

/// Writes the raw recording plus the on-screen summary, for offline analysis.
enum Exporter {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PointerSync/measurements", isDirectory: true)
    }

    private struct File: Encodable {
        var created: String
        var macOS: String
        var model: String
        var status: Status
        var summary: [String]
        var devices: [DeviceInfo]
        var displays: [DisplayInfo]
        var layouts: [Layout]
        var probes: [ProbeSample]
        var pointer: [PointerSample]
        var scales: [ScaleSample]
        var reports: [HIDReport]
        var values: [HIDValue]
        var events: [PointerEvent]
        var frames: [Frame]
    }

    static func save(summary: [String]) throws -> URL {
        let snap = Recorder.shared.snapshot(since: Clock.now() - AppModel.keep)
        let stamp = Date()
        let file = File(created: ISO8601DateFormatter().string(from: stamp),
                        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                        model: hardwareModel(),
                        status: snap.status,
                        summary: summary,
                        devices: snap.devices,
                        displays: snap.displays.values.sorted { $0.id < $1.id },
                        layouts: snap.layouts,
                        probes: snap.probes,
                        pointer: snap.pointer,
                        scales: snap.scales,
                        reports: snap.reports,
                        values: snap.values,
                        events: snap.events,
                        frames: snap.frames)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = DateFormatter()
        name.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("measure-\(name.string(from: stamp)).json")
        try JSONEncoder().encode(file).write(to: url)
        return url
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
