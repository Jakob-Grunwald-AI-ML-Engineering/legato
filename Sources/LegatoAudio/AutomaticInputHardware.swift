import AVFAudio
import Foundation
import LegatoCore
#if os(macOS)
import CoreAudio
#endif

public struct AudioInputPlatformStatus: Sendable, Codable {
    public let available: [AudioInputCandidate]
    public let currentIDs: [String]
    public let preferredID: String?
    public let sampleRate: Double?
}

extension AutomaticInputSource {
    /// Read-only inventory; does not activate a session, capture audio, or change routing.
    public static func platformStatus() -> AudioInputPlatformStatus {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return .init(available: AutomaticInputHardware.platformInputs(), currentIDs: session.currentRoute.inputs.map(\.uid),
            preferredID: session.preferredInput?.uid, sampleRate: session.sampleRate)
        #else
        return .init(available: AutomaticInputHardware.platformInputs(), currentIDs: [], preferredID: nil, sampleRate: nil)
        #endif
    }
}

extension AutomaticInputHardware {
    static let live = Self(candidates: { platformInputs() }, make: { candidate in
        #if os(iOS)
        PreferredSessionInput(uid: candidate.id)
        #else
        MeetingHALMicSource(device: UInt32(candidate.id) ?? 0)
        #endif
    }, isCurrent: { candidate in
        #if os(iOS)
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.uid == candidate.id }
        #else
        platformInputs().contains { $0.id == candidate.id && $0.isUsable }
        #endif
    })

    static func platformInputs() -> [AudioInputCandidate] {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let current = Set(session.currentRoute.inputs.map(\.uid))
        return (session.availableInputs ?? []).map { port in
            let kind: AudioInputCandidate.Kind
            switch port.portType {
            case .builtInMic: kind = .builtIn
            case .headsetMic, .usbAudio, .lineIn: kind = .wired
            case .bluetoothHFP, .bluetoothLE: kind = .bluetooth
            default: kind = .other
            }
            return .init(id: port.uid, name: port.portName, kind: kind,
                channels: port.channels?.count,
                sampleRate: current.contains(port.uid) && session.sampleRate > 0 ? session.sampleRate : nil)
        }
        #else
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            let inputs = channelCount(device)
            guard inputs > 0 else { return nil }
            let transport: UInt32 = scalar(device, kAudioDevicePropertyTransportType) ?? 0
            let classID: UInt32 = scalar(device, kAudioObjectPropertyClass) ?? 0
            let kind: AudioInputCandidate.Kind
            if classID == kAudioAggregateDeviceClassID || transport == kAudioDeviceTransportTypeAggregate { kind = .aggregate }
            else {
                switch transport {
                case kAudioDeviceTransportTypeBuiltIn: kind = .builtIn
                case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
                     kAudioDeviceTransportTypePCI: kind = .wired
                case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: kind = .bluetooth
                case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: kind = .continuity
                case kAudioDeviceTransportTypeVirtual: kind = .virtual
                default: kind = .other
                }
            }
            let alive: UInt32 = scalar(device, kAudioDevicePropertyDeviceIsAlive) ?? 0
            let rate: Double = scalar(device, kAudioDevicePropertyNominalSampleRate) ?? 0
            return .init(id: String(device), name: name(device) ?? "Microphone", kind: kind,
                available: alive != 0, channels: inputs, sampleRate: rate)
        }
        #endif
    }
    #if os(macOS)
    private static func scalar<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return nil }
        return storage.load(as: T.self)
    }
    private static func name(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func channelCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    #endif
}

#if os(iOS)
/// AVAudioSession is already active through the host's existing foreground/lease admission.
private actor PreferredSessionInput: AudioSource {
    let uid: String
    let inner = MicSource()
    init(uid: String) { self.uid = uid }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else { throw AutomaticInputError.noUsableInput }
        if !session.currentRoute.inputs.contains(where: { $0.uid == uid }) { try session.setPreferredInput(port) }
        for _ in 0..<10 {
            try Task.checkCancellation()
            if session.currentRoute.inputs.contains(where: { $0.uid == uid }) { return try await inner.start(format: format) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AutomaticInputError.noUsableInput
    }
    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async { await inner.stop() }
}
#endif
