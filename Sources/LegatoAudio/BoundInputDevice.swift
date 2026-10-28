#if os(macOS)
import CoreAudio
import Foundation
import Synchronization

/// Owns the private full-duplex device needed when the requested microphone has no output side.
/// Retain for the engine's entire lifetime; stop the engine before releasing or destroying this owner.
final class BoundInputDevice: Sendable {
    struct Device: Sendable {
        let id: UInt32
        let uid: String
        let inputs: Int
        let outputs: Int
    }
    struct Plan: Sendable {
        let input: Device
        let output: Device
    }
    struct Hardware: Sendable {
        let describe: @Sendable (UInt32) throws -> Device
        let defaultOutput: @Sendable () throws -> UInt32
        let create: @Sendable (Plan) throws -> UInt32
        let destroy: @Sendable (UInt32) -> Void
    }
    enum Failure: Error, LocalizedError {
        case unavailable, outputContainsAnotherMicrophone, coreAudio(Int32)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The selected microphone or output device is unavailable."
            case .outputContainsAnotherMicrophone: "This output includes another microphone; choose an output-only device for this microphone."
            case .coreAudio(let status): "Could not create the microphone audio device (Core Audio \(status))."
            }
        }
    }

    let device: UInt32
    private let owned: Mutex<UInt32?>
    private let destroyDevice: @Sendable (UInt32) -> Void

    convenience init(input: UInt32) throws { try self.init(input: input, hardware: .live) }

    init(input: UInt32, hardware: Hardware) throws {
        let selected = try hardware.describe(input)
        guard selected.id != kAudioObjectUnknown, selected.inputs > 0, !selected.uid.isEmpty else { throw Failure.unavailable }
        destroyDevice = hardware.destroy
        if selected.outputs > 0 {
            device = selected.id
            owned = Mutex(nil)
        } else {
            let output = try hardware.describe(hardware.defaultOutput())
            guard output.id != kAudioObjectUnknown, output.outputs > 0, !output.uid.isEmpty,
                output.uid != selected.uid else { throw Failure.unavailable }
            // Never add another input to the aggregate: downstream mono conversion could mix that microphone in.
            guard output.inputs == 0 else { throw Failure.outputContainsAnotherMicrophone }
            let made = try hardware.create(Plan(input: selected, output: output))
            guard made != kAudioObjectUnknown else { throw Failure.unavailable }
            device = made
            owned = Mutex(made)
            // Aggregate channels become available asynchronously. The engine's existing launch retry loop
            // validates the settled format; do not create another aggregate for each retry.
        }
    }

    func destroy() {
        let id = owned.withLock { value in defer { value = nil }; return value }
        if let id { destroyDevice(id) }
    }
    deinit { destroy() }
}

extension BoundInputDevice.Hardware {
    static let live = Self(describe: { id in
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw BoundInputDevice.Failure.unavailable }
        return BoundInputDevice.Device(id: id, uid: uid.takeRetainedValue() as String,
            inputs: try channels(id, scope: kAudioObjectPropertyScopeInput),
            outputs: try channels(id, scope: kAudioObjectPropertyScopeOutput))
    }, defaultOutput: {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = UInt32(kAudioObjectUnknown), size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else { throw BoundInputDevice.Failure.coreAudio(status) }
        return id
    }, create: { plan in
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LegatoMeetingMic",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: plan.input.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: plan.input.uid],
                [kAudioSubDeviceUIDKey: plan.output.uid, kAudioSubDeviceDriftCompensationKey: true],
            ],
        ]
        var id = UInt32(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else {
            if id != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(id) }
            throw BoundInputDevice.Failure.coreAudio(status)
        }
        return id
    }, destroy: { AudioHardwareDestroyAggregateDevice($0) })

    private static func channels(_ id: UInt32, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == noErr else { throw BoundInputDevice.Failure.coreAudio(status) }
        guard size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let read = AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory)
        guard read == noErr else { throw BoundInputDevice.Failure.coreAudio(read) }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
