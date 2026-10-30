#if os(macOS)
import CoreAudio
import Foundation

/// One entry of the Core Audio process list (macOS 14.2+).
public struct AudioProcessInfo: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String
    public var isRunningInput: Bool
    public var isRunningOutput: Bool
    /// The public input devices it records from (`kAudioProcessPropertyDevices`, input scope); empty when it
    /// records nothing. Private devices (a voice-processing aggregate) are left out.
    public var inputDevices: [UInt32] = []
}

/// Reads which processes have the mic and the speakers open (`kAudioProcessPropertyIsRunningInput` / `IsRunningOutput`),
/// and which input devices they record from. Feeds `AutoMutePolicy` and `MeetingMicRoute`; which call apps close the
/// mic on mute is a device measurement (spike task 0).
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
        let devices = Set(AudioDevices.all())
        return ids.compactMap { id in
            guard let pid: Int32 = Self.scalar(id, kAudioProcessPropertyPID) else { return nil }
            let input = (Self.scalar(id, kAudioProcessPropertyIsRunningInput) as UInt32? ?? 0) != 0
            return AudioProcessInfo(
                pid: pid, bundleID: Self.string(id, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: input,
                isRunningOutput: (Self.scalar(id, kAudioProcessPropertyIsRunningOutput) as UInt32? ?? 0) != 0,
                inputDevices: input ? AudioDevices.ids(of: id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
                    .filter(devices.contains) : [])
        }
    }

    /// The processes with the mic or the speakers running now (our own included; `AutoMutePolicy` drops it).
    public func activeProcesses() throws -> [AutoMuteProcess] {
        try snapshot().filter { $0.isRunningInput || $0.isRunningOutput }.map {
            AutoMuteProcess(
                pid: $0.pid, isRunningInput: $0.isRunningInput, isRunningOutput: $0.isRunningOutput,
                inputDevices: $0.inputDevices)
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

/// Core Audio device reads for the meeting mic: the default input, the device list, names.
public enum AudioDevices {
    /// The system default input device.
    public static func defaultInput() -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Device IDs visible to this process, including its own private aggregates.
    public static func all() -> [UInt32] {
        ids(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
    }

    /// Public devices that actually have input channels. UIDs remain stable across reconnects.
    public static func inputs() -> [(id: UInt32, uid: String, name: String)] {
        all().compactMap { id in
            guard classification(of: id).isSelectable else { return nil }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr,
                UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains(where: { $0.mNumberChannels > 0 }),
                let uid = uid(of: id) else { return nil }
            return (id, uid, name(of: id) ?? uid)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Aggregates can duplicate physical microphones already captured in Auto and All modes.
    public static func isAggregate(_ device: UInt32) -> Bool { classification(of: device).isAggregate }

    private static func classification(of device: UInt32) -> MeetingInputClassification {
        let classID = scalar(device, kAudioObjectPropertyClass)
        let transport = scalar(device, kAudioDevicePropertyTransportType)
        let aggregate = classID == kAudioAggregateDeviceClassID || transport == kAudioDeviceTransportTypeAggregate
        var isPrivate = false
        if aggregate {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyComposition, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var composition: Unmanaged<CFDictionary>?
            var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &composition) == noErr,
                let dictionary = composition?.takeRetainedValue() as? [String: Any] {
                isPrivate = (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
            }
        }
        return MeetingInputClassification(classID: classID, transport: transport, isPrivate: isPrivate)
    }

    private static func scalar(_ device: UInt32, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    public static func uid(of device: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// A device's name, for notices.
    public static func name(of device: UInt32) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// An object-ID array property; empty when the read fails.
    static func ids(
        of object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> [UInt32] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

/// Pure Core Audio classification policy; device reads are kept at the boundary.
struct MeetingInputClassification {
    let classID: UInt32?
    let transport: UInt32?
    let isPrivate: Bool
    var isAggregate: Bool { classID == kAudioAggregateDeviceClassID || transport == kAudioDeviceTransportTypeAggregate }
    var isSelectable: Bool { !isPrivate }
}

public enum MicInUseError: Error, Sendable, Equatable {
    case coreAudio(call: String, status: Int32)
}
#endif
