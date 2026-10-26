import CoreAudio
import Foundation
import Observation

struct AudioProcessInfo: Identifiable, Sendable, Equatable {
    var pid: Int32
    var bundleID: String
    var input: Bool
    var output: Bool
    var id: String { "\(pid)|\(bundleID)" }
}

/// Polls the Core Audio process object list once per second (macOS 14.2+) and logs input/output flips as JSON lines.
@MainActor @Observable
final class ProcessMonitor {
    static let logPath = "/tmp/legato-spike-mic-usage.jsonl"

    private(set) var active: [AudioProcessInfo] = []
    private(set) var totalProcesses = 0
    private(set) var lastError = ""
    private var task: Task<Void, Never>?
    private var previous: [String: AudioProcessInfo] = [:]

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func poll() {
        let all: [AudioProcessInfo]
        do { all = try Self.readProcesses() } catch {
            lastError = "\(error)"
            return
        }
        lastError = ""
        totalProcesses = all.count
        let current = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Transitions: new/changed entries, and entries that vanished (reported as in=false/out=false).
        for (key, now) in current where previous[key].map({ $0.input != now.input || $0.output != now.output }) ?? (now.input || now.output) {
            log(now, prev: previous[key])
        }
        for (key, old) in previous where current[key] == nil && (old.input || old.output) {
            log(AudioProcessInfo(pid: old.pid, bundleID: old.bundleID, input: false, output: false), prev: old, gone: true)
        }
        previous = current
        active = all.filter { $0.input || $0.output }.sorted { $0.bundleID < $1.bundleID }
    }

    private func log(_ p: AudioProcessInfo, prev: AudioProcessInfo?, gone: Bool = false) {
        var obj: [String: Any] = [
            "t": ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]),
            "pid": p.pid, "bundle": p.bundleID, "input": p.input, "output": p.output,
        ]
        if let prev { obj["prevInput"] = prev.input; obj["prevOutput"] = prev.output }
        if gone { obj["processGone"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let line = data + Data("\n".utf8)
        let url = URL(fileURLWithPath: Self.logPath)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Core Audio reads

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readProcesses() throws -> [AudioProcessInfo] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard err == noErr else { throw CaptureError("process list size failed: OSStatus \(err)") }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard err == noErr else { throw CaptureError("process list failed: OSStatus \(err)") }
        return ids.compactMap { id in
            guard let pid: Int32 = scalar(id, kAudioProcessPropertyPID) else { return nil }
            return AudioProcessInfo(
                pid: pid, bundleID: string(id, kAudioProcessPropertyBundleID) ?? "(none)",
                input: (scalar(id, kAudioProcessPropertyIsRunningInput) as UInt32? ?? 0) != 0,
                output: (scalar(id, kAudioProcessPropertyIsRunningOutput) as UInt32? ?? 0) != 0)
        }
    }

    private static func scalar<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
