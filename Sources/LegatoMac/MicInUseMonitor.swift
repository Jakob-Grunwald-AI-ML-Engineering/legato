#if os(macOS)
import CoreAudio
import Foundation

/// One entry of the Core Audio process list (macOS 14.2+).
public struct AudioProcessInfo: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String
    public var isRunningInput: Bool
    public var isRunningOutput: Bool
}

/// Reads which processes have the mic and the speakers open (`kAudioProcessPropertyIsRunningInput` / `IsRunningOutput`). Feeds
/// `AutoMutePolicy`; which call apps close the mic on mute is a device measurement (spike task 0).
public struct MicInUseMonitor: Sendable {
    public let interval: Duration

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    /// The whole process list now. Throws when Core Audio refuses the read.
    public func snapshot() throws -> [AudioProcessInfo] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size)
        guard err == noErr else { throw MicInUseError.coreAudio(call: "process list size", status: err) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids)
        guard err == noErr else { throw MicInUseError.coreAudio(call: "process list", status: err) }
        return ids.compactMap { id in
            guard let pid: Int32 = Self.scalar(id, kAudioProcessPropertyPID) else { return nil }
            return AudioProcessInfo(
                pid: pid, bundleID: Self.string(id, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: (Self.scalar(id, kAudioProcessPropertyIsRunningInput) as UInt32? ?? 0) != 0,
                isRunningOutput: (Self.scalar(id, kAudioProcessPropertyIsRunningOutput) as UInt32? ?? 0) != 0)
        }
    }

    /// The processes with the mic or the speakers running now (our own included; `AutoMutePolicy` drops it).
    public func activeProcesses() throws -> [AutoMuteProcess] {
        try snapshot().filter { $0.isRunningInput || $0.isRunningOutput }.map {
            AutoMuteProcess(pid: $0.pid, isRunningInput: $0.isRunningInput, isRunningOutput: $0.isRunningOutput)
        }
    }

    /// The active processes, polled every `interval`; yields on change (and once at the start).
    /// Read errors are skipped. Ends when the consumer stops iterating.
    public func processChanges() -> AsyncStream<[AutoMuteProcess]> {
        let monitor = self
        return AsyncStream { continuation in
            let task = Task {
                var last: Set<AutoMuteProcess>?
                while !Task.isCancelled {
                    if let now = try? monitor.activeProcesses(), Set(now) != last {
                        last = Set(now)
                        continuation.yield(now)
                    }
                    try? await Task.sleep(for: monitor.interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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

public enum MicInUseError: Error, Sendable, Equatable {
    case coreAudio(call: String, status: Int32)
}
#endif
