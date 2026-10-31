#if os(macOS)
import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import LegatoCore
import Synchronization

protocol MeetingHALInputLease: Sendable {
    func start() throws
    func stop()
}

/// A fixed, input-only HAL unit. Unlike AVAudioEngine, it never opens or rebinds an output device.
public actor MeetingHALMicSource: AudioSource {
    typealias Factory = @Sendable (UInt32, AudioFormatSpec, TapRouter) throws -> any MeetingHALInputLease
    private let device: UInt32
    private let factory: Factory
    private var router = TapRouter()
    private var lease: (any MeetingHALInputLease)?

    public init(device: UInt32, onDiagnostic: (@Sendable (MicSource.Diagnostic) -> Void)? = nil) {
        self.device = device
        self.factory = { device, format, router in
            try HALInputLease(device: device, format: format, router: router, diagnostic: onDiagnostic)
        }
    }

    init(device: UInt32, factory: @escaping Factory) { self.device = device; self.factory = factory }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        stopCurrent()
        // Already queued callbacks retain their old router, so they cannot end a new lease.
        router = TapRouter()
        let stream = makeStream()
        do {
            let fresh = try factory(device, format, router)
            do { try fresh.start() }
            catch { fresh.stop(); throw error }
            lease = fresh
        } catch {
            router.setSink(nil)
            throw error
        }
        return stream
    }
    public func route() async throws -> AsyncStream<AudioChunk> {
        guard lease != nil else { throw MicSourceError.notArmed }
        return makeStream()
    }
    public func detach() async { router.setSink(nil) }
    public func stop() async { stopCurrent() }
    private func stopCurrent() {
        router.setSink(nil)
        lease?.stop(); lease = nil
    }
    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, sink) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(32))
        router.setSink(sink)
        return stream
    }
}

private struct HALInputFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "Microphone \(operation) failed (Core Audio \(status))." }
}

/// AudioUnitRender writes into this lease-owned buffer; converted chunks copy their samples out.
private final class HALRenderContext: @unchecked Sendable {
    let unit: AudioUnit
    let buffer: AVAudioPCMBuffer
    let converter: BufferConverter
    let router: TapRouter
    let probe: FirstBufferProbe?
    init(unit: AudioUnit, buffer: AVAudioPCMBuffer, converter: BufferConverter, router: TapRouter,
         probe: FirstBufferProbe?) {
        self.unit = unit; self.buffer = buffer; self.converter = converter; self.router = router; self.probe = probe
    }
}

private let halInputCallback: AURenderCallback = { reference, flags, time, _, frames, _ in
    let context = Unmanaged<HALRenderContext>.fromOpaque(reference).takeUnretainedValue()
    guard frames <= context.buffer.frameCapacity else {
        context.router.setSink(nil)
        return kAudioUnitErr_TooManyFramesToProcess
    }
    context.buffer.frameLength = frames
    let status = AudioUnitRender(context.unit, flags, time, 1, frames, context.buffer.mutableAudioBufferList)
    guard status == noErr else {
        context.router.setSink(nil)
        return status
    }
    context.probe?.observe(context.buffer)
    if let chunk = context.converter.convert(context.buffer) { context.router.handle(chunk) }
    return noErr
}

private final class HALInputLease: MeetingHALInputLease, @unchecked Sendable {
    private let unit: AudioUnit
    private let device: UInt32
    private let diagnostic: (@Sendable (MicSource.Diagnostic) -> Void)?
    private let stopped = Mutex(false)
    private var context: HALRenderContext?
    private let listenerQueue = DispatchQueue(label: "de.gruenwald.legato.meeting-input-device")
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(device: UInt32, format: AudioFormatSpec, router: TapRouter,
         diagnostic: (@Sendable (MicSource.Diagnostic) -> Void)?) throws {
        self.device = device; self.diagnostic = diagnostic
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MicSourceError.invalidInputFormat }
        var made: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &made), "create")
        guard let made else { throw MicSourceError.invalidInputFormat }
        unit = made
        do {
            var enabled: UInt32 = 1, disabled: UInt32 = 0, selected = device
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1, &enabled)
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0, &disabled)
            try set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0, &selected)
            try verifyDevice()
            var native = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &native, &size), "read input format")
            guard native.mSampleRate.isFinite, native.mSampleRate > 0, native.mChannelsPerFrame > 0,
                  let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.mSampleRate,
                      channels: native.mChannelsPerFrame, interleaved: false),
                  let converter = BufferConverter(from: inputFormat, to: format) else { throw MicSourceError.invalidInputFormat }
            var client = inputFormat.streamDescription.pointee
            try set(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, bus: 1, &client)
            try Self.check(AudioUnitInitialize(unit), "initialize")
            var maxFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &maxFrames, &size), "read render capacity")
            guard maxFrames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames)
            else { throw MicSourceError.invalidInputFormat }
            let probe = diagnostic.map { report in FirstBufferProbe(sampleRate: inputFormat.sampleRate) { buffer in
                report(MicSource.Diagnostic(event: "engine.firstBuffer", fields: [
                    "requested": String(device), "msSinceStart": String(buffer.msSinceStart), "rms": String(buffer.rms),
                    "frames": String(buffer.frames), "rate": String(buffer.sampleRate), "capture": "input-only-hal",
                ]))
            } }
            let context = HALRenderContext(unit: unit, buffer: buffer, converter: converter, router: router, probe: probe)
            self.context = context
            var callback = AURenderCallbackStruct(inputProc: halInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try set(kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, bus: 0, &callback)
            for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                let listener: AudioObjectPropertyListenerBlock = { _, _ in router.setSink(nil) }
                try Self.check(AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, listener), "observe input")
                listeners.append((address, listener))
            }
        } catch {
            stop()
            throw error
        }
    }

    func start() throws {
        try verifyDevice()
        try Self.check(AudioOutputUnitStart(unit), "start")
        try verifyDevice()
        diagnostic?(MicSource.Diagnostic(event: "engine.started", fields: [
            "requested": String(device), "boundDevice": String(device), "currentDeviceElement0": String(device),
            "running": "true", "strictDevice": "true", "capture": "input-only-hal", "error": "none",
        ]))
    }

    func stop() {
        stopped.withLock { done in
            guard !done else { return }
            done = true
            for (var address, listener) in listeners {
                AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, listener)
            }
            listeners.removeAll()
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            // The native unit cannot invoke its borrowed callback pointer after disposal.
            context = nil
        }
    }
    deinit { stop() }

    private func verifyDevice() throws {
        var actual: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &actual, &size), "verify input")
        guard actual == device else { throw MicSourceError.deviceNotSelected(device: device, status: 0) }
    }
    private func set<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, scope: AudioUnitScope, bus: AudioUnitElement, _ value: inout T) throws {
        try Self.check(AudioUnitSetProperty(unit, property, scope, bus, &value, UInt32(MemoryLayout<T>.size)), "configure input")
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw HALInputFailure(operation: operation, status: status) }
    }
}
#endif
