import Foundation
import Synchronization
import Darwin

/// Fixture records may contain text; operational events contain only counts and state.
public final class RunRecorder: Sendable {
    public let directory: URL
    private let lock = Mutex(())
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func record(_ row: Measurement) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(row) { append(data, name: "measurements.jsonl") }
    }
    public func event(_ name: String, fields: [String: String] = [:]) {
        var values = fields
        values["event"] = name; values["time"] = ISO8601DateFormatter().string(from: Date())
        values["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        if let data = try? JSONEncoder().encode(values) { append(data, name: "events.jsonl") }
    }
    private func append(_ data: Data, name: String) {
        lock.withLock { _ in
            let url = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data + [10]); try handle.synchronize() } catch {}
        }
    }
}
public final class MemorySampler: Sendable {
    private let peak = Mutex(UInt64(0))
    public init() {}
    public func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS { peak.withLock { $0 = max($0, info.phys_footprint) } }
    }
    public var sampledPeakBytes: UInt64 { peak.withLock { $0 } }
}
