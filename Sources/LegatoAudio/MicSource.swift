import AVFAudio
import LegatoCore
import Synchronization
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

public enum MicSourceError: Error, Sendable, Equatable {
    /// `route()` without a preceding `start(format:)`, or after the engine stopped.
    case notArmed
    /// The input node reported a zero sample rate or channel count (session not ready).
    case invalidInputFormat
    /// No converter from the input format to the requested format.
    case converterUnavailable
    /// The input could not be bound to this Core Audio device (macOS). `status` is the OSStatus of the
    /// call, or 0 when it succeeded but the unit kept another device.
    case deviceNotSelected(device: UInt32, status: Int32)
}

/// Audio-thread side: forwards converted chunks to the current run's stream.
final class TapRouter: Sendable {
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)

    /// Installs `new` as the sink and finishes the previous one.
    func setSink(_ new: AsyncStream<AudioChunk>.Continuation?) {
        let old = continuation.withLock { c in
            let previous = c
            c = new
            return previous
        }
        old?.finish()
    }

    func handle(_ chunk: AudioChunk) {
        _ = continuation.withLock { $0 }?.yield(chunk)
    }
}

/// Realtime-thread probe: when the first buffer arrived and how loud the first ~0.5 s were.
final class FirstBufferProbe: Sendable {
    private struct State {
        var firstMs: Int?
        var sumSquares = 0.0
        var frames = 0
        var done = false
    }

    private let state = Mutex(State())
    private let started: ContinuousClock.Instant
    private let sampleRate: Double
    private let report: @Sendable (MicSource.FirstBuffer) -> Void

    init(sampleRate: Double, report: @escaping @Sendable (MicSource.FirstBuffer) -> Void) {
        self.started = .now
        self.sampleRate = sampleRate
        self.report = report
    }

    func observe(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        var sum = 0.0
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<frames { let v = Double(data[i]); sum += v * v }
        }
        let result: MicSource.FirstBuffer? = state.withLock { s in
            guard !s.done else { return nil }
            if s.firstMs == nil {
                let d = ContinuousClock.now - started
                s.firstMs = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
            }
            s.sumSquares += sum
            s.frames += frames
            guard Double(s.frames) >= sampleRate * 0.5 else { return nil }
            s.done = true
            return MicSource.FirstBuffer(
                msSinceStart: s.firstMs ?? 0, rms: (s.sumSquares / Double(max(s.frames, 1))).squareRoot(),
                frames: s.frames, sampleRate: sampleRate)
        }
        if let result { report(result) }
    }
}

/// Microphone `AudioSource`. The engine runs for a whole lease; runs attach and detach streams.
public final class MicSource: ResumableAudioSource {
    private struct State {
        var engine: EngineBox?
        /// Bumped by every start and stop, so a restart that lost the race to either drops its engine.
        var lease = 0
        var format: AudioFormatSpec?
        var observer: ObserverBox?
    }

    /// Holds the configuration-change observer token (not Sendable) inside the lock.
    private final class ObserverBox: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ token: any NSObjectProtocol) { self.token = token }
    }

    /// Lets the engine cross into the lock under Swift 6.2's region checks. Safe: once stored, the
    /// engine is only touched by `route()` (reads `isRunning`) and by `stop()` after taking it out.
    private final class EngineBox: @unchecked Sendable {
        let engine: AVAudioEngine
        #if os(macOS)
        let boundInput: BoundInputDevice?
        var boundDevice: UInt32? { boundInput?.device }
        init(_ engine: AVAudioEngine, boundInput: BoundInputDevice? = nil) {
            self.engine = engine
            self.boundInput = boundInput
        }
        #else
        init(_ engine: AVAudioEngine) { self.engine = engine }
        #endif

        func stop() {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            #if os(macOS)
            boundInput?.destroy()
            #endif
        }
    }

    /// Opt-in metadata only: lifecycle and audio measurements, never samples or transcript text.
    public struct Diagnostic: Sendable {
        public let event: String
        public let fields: [String: String]
    }

    /// The outcome of one engine start attempt, for diagnostics.
    public struct Attempt: Sendable {
        /// 0-based; at most `maxAttempts` per `start(format:)`.
        public let index: Int
        /// The input node's format on this attempt (0 when the route was not ready).
        public let inputSampleRate: Double
        public let inputChannelCount: Int
        /// nil when the engine started.
        public let error: (any Error)?
    }

    /// Signal check after a successful start, for diagnostics: no callback means no buffer arrived.
    public struct FirstBuffer: Sendable {
        /// From just before the engine started to the first tap buffer.
        public let msSinceStart: Int
        /// RMS (0...1) of the first channel over the first ~0.5 s of input.
        public let rms: Double
        public let frames: Int
        public let sampleRate: Double
    }

    /// 8 attempts, 150 ms apart.
    static let maxAttempts = 8
    static let retryDelay: Duration = .milliseconds(150)

    private let state = Mutex(State())
    private let router = TapRouter()
    private let onAttempt: (@Sendable (Attempt) -> Void)?
    private let onFirstBuffer: (@Sendable (FirstBuffer) -> Void)?
    private let onDiagnostic: (@Sendable (Diagnostic) -> Void)?
    /// A source-scoped engine event. Recheck after scheduling: stop/start can supersede it meanwhile.
    public struct ConfigurationChange: Sendable {
        private let validate: @Sendable () -> Bool
        fileprivate init(validate: @escaping @Sendable () -> Bool) { self.validate = validate }
        public var requiresStop: Bool { validate() }
    }

    private let onConfigurationChange: (@Sendable (ConfigurationChange) -> Void)?
    private let voiceProcessing: Bool
    private let device: UInt32?
    private let strictDevice: Bool
    private let resumeSink: AsyncStream<Void>.Continuation

    /// Yields each time the engine was rebuilt after a device or format change (macOS), so a meeting can
    /// fill the time the mic did not deliver. A rebuild that fails ends the chunk stream instead.
    public let resumptions: AsyncStream<Void>

    /// - Parameters:
    ///   - voiceProcessing: macOS only; ignored on iOS. Turns on Apple's voice processing (echo
    ///     cancellation) on the input before the engine starts, with other-audio ducking at its
    ///     minimum. Off by default, so dictation is unchanged. The input then reports many channels
    ///     and the converter takes channel 0 (the processed voice; an assumption from the spike).
    ///   - onAttempt: called after every start attempt, success or failure (diagnostics only).
    ///   - onFirstBuffer: called once per started engine, after ~0.5 s of input (diagnostics only).
    ///   - device: macOS only; ignored on iOS. The Core Audio input device to record from, bound on every fresh
    ///     engine before its format is read. nil (the default) records from the system default input and follows
    ///     it. A device that cannot be bound makes `start(format:)` throw `MicSourceError.deviceNotSelected`;
    ///     when it goes away later, the rebuilt engine records from the default input unless strictDevice is true.
    ///   - onConfigurationChange: iOS only; schedules invalidation after this source's engine stops for a
    ///     configuration change. Check `requiresStop` again when handling it, as stop/start can supersede it.
    public init(
        onAttempt: (@Sendable (Attempt) -> Void)? = nil,
        onFirstBuffer: (@Sendable (FirstBuffer) -> Void)? = nil,
        onDiagnostic: (@Sendable (Diagnostic) -> Void)? = nil,
        voiceProcessing: Bool = false,
        device: UInt32? = nil,
        strictDevice: Bool = false,
        onConfigurationChange: (@Sendable (ConfigurationChange) -> Void)? = nil
    ) {
        self.onConfigurationChange = onConfigurationChange
        self.onDiagnostic = onDiagnostic
        self.onAttempt = { attempt in
            onAttempt?(attempt)
            onDiagnostic?(Diagnostic(event: "engine.attempt", fields: [
                "attempt": String(attempt.index), "rate": String(attempt.inputSampleRate),
                "channels": String(attempt.inputChannelCount), "requested": device.map(String.init) ?? "default",
                "error": attempt.error.map { String(describing: $0) } ?? "none",
            ]))
        }
        if onFirstBuffer != nil || onDiagnostic != nil {
            self.onFirstBuffer = { buffer in
                onFirstBuffer?(buffer)
                onDiagnostic?(Diagnostic(event: "engine.firstBuffer", fields: [
                    "msSinceStart": String(buffer.msSinceStart), "rms": String(buffer.rms),
                    "frames": String(buffer.frames), "rate": String(buffer.sampleRate),
                ]))
            }
        } else {
            self.onFirstBuffer = nil
        }
        self.voiceProcessing = voiceProcessing
        self.strictDevice = strictDevice
        self.device = device
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stop()
        state.withLock { s in
            s.lease += 1
            s.format = format
        }
        let box = try await launchEngine(format: format, device: device)
        state.withLock { $0.engine = box }
        installConfigurationObserver(for: box)
        return makeStream()
    }

    /// Builds, taps and starts a fresh engine on `device` (nil: the default input), retrying while the route settles.
    private func launchEngine(format: AudioFormatSpec, device: UInt32?) async throws -> EngineBox {
        #if os(macOS)
        // One owned full-duplex device for this retry sequence. Creating one per attempt never lets it settle.
        let boundInput = try device.map { try BoundInputDevice(input: $0) }
        let boundDevice = boundInput?.device
        #else
        let device: UInt32? = nil // devices are macOS only
        #endif
        // The route can still be settling right after session activation (kAUStartIO 'what', or a
        // zero input sample rate), and an engine that failed to start stays unusable. So every
        // attempt builds a fresh engine, after the session is active (an engine made earlier caches
        // an input format that installTap then rejects), and is gated on a valid input format.
        var lastError: (any Error)?
        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 { try await Task.sleep(for: Self.retryDelay) }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            #if os(macOS)
            if voiceProcessing {
                // Before the engine starts. The input format changes with it, so it is read afterwards.
                do {
                    try input.setVoiceProcessingEnabled(true)
                } catch {
                    lastError = error
                    onAttempt?(Attempt(index: attempt, inputSampleRate: 0, inputChannelCount: 0, error: error))
                    continue
                }
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min)
            }
            // On this fresh engine, after voice processing (which puts the unit back on the default devices),
            // before the format is read.
            if let boundDevice, let error = Self.bind(input, to: boundDevice) {
                let failure: MicSourceError
                if case .deviceNotSelected(_, let status) = error {
                    failure = .deviceNotSelected(device: device ?? boundDevice, status: status)
                } else { failure = error }
                lastError = failure
                onAttempt?(Attempt(index: attempt, inputSampleRate: 0, inputChannelCount: 0, error: failure))
                engine.stop()
                continue
            }
            #endif
            let inFormat = Self.tapFormat(
                output: input.outputFormat(forBus: 0), hardware: input.inputFormat(forBus: 0),
                bound: device != nil, voiceProcessing: voiceProcessing)
            let report = { [onAttempt] (error: (any Error)?) in
                onAttempt?(Attempt(
                    index: attempt, inputSampleRate: inFormat.sampleRate,
                    inputChannelCount: Int(inFormat.channelCount), error: error))
            }
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
                lastError = MicSourceError.invalidInputFormat
                report(lastError)
                continue
            }
            guard let converter = BufferConverter(from: inFormat, to: format, firstChannelOnly: voiceProcessing) else {
                report(MicSourceError.converterUnavailable)
                throw MicSourceError.converterUnavailable
            }
            let probe = onFirstBuffer.map { FirstBufferProbe(sampleRate: inFormat.sampleRate, report: $0) }
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat, block: Self.tapBlock(router, converter, probe))
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                engine.stop()
                lastError = error
                report(error)
                continue
            }
            report(nil)
            #if os(macOS)
            diagnose("engine.started", engine: engine, boundDevice: boundDevice)
            return EngineBox(engine, boundInput: boundInput)
            #else
            diagnose("engine.started", engine: engine)
            return EngineBox(engine)
            #endif
        }
        throw lastError ?? MicSourceError.invalidInputFormat
    }

    public func route() async throws -> AsyncStream<AudioChunk> {
        guard state.withLock({ $0.engine?.engine.isRunning == true }) else { throw MicSourceError.notArmed }
        return makeStream()
    }

    public func detach() async {
        router.setSink(nil)
    }

    public func stop() async {
        router.setSink(nil)
        let (engine, observer) = state.withLock { s in
            let taken = (s.engine, s.observer)
            s.engine = nil
            s.observer = nil
            s.lease += 1
            return taken
        }
        if let observer { NotificationCenter.default.removeObserver(observer.token) }
        engine?.stop()
    }

    /// macOS: a device or format change stops the engine; with the lease armed it is rebuilt and the
    /// current run's stream carries on. iOS reports only a stopped engine belonging to this source.
    private func installConfigurationObserver(for box: EngineBox) {
        #if os(macOS)
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: box.engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.restartAfterConfigurationChange(box) }
        }
        state.withLock { $0.observer = ObserverBox(token) }
        #else
        guard let onConfigurationChange else { return }
        let token = Self.observeConfigurationChanges(of: box.engine, isCurrent: { [weak self] in
            self?.state.withLock { $0.engine === box } == true
        }, onChange: onConfigurationChange)
        state.withLock { $0.observer = ObserverBox(token) }
        #endif
    }

    /// Kept separate so source filtering and queued-event validity can be checked without opening a mic.
    static func observeConfigurationChanges(
        of engine: AVAudioEngine, isCurrent: @escaping @Sendable () -> Bool,
        onChange: @escaping @Sendable (ConfigurationChange) -> Void
    ) -> any NSObjectProtocol {
        let box = EngineBox(engine)
        return NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            let change = ConfigurationChange { isCurrent() && !box.engine.isRunning }
            guard change.requiresStop else { return }
            onChange(change) // only schedules work; never tears down an engine on its notification queue
        }
    }

    private func restartAfterConfigurationChange(_ old: EngineBox) async {
        #if os(macOS)
        // Binding a device posts a change of its own while the engine runs on, on that device.
        let current = old.engine.inputNode.audioUnit.flatMap { Self.inputDevice(of: $0) }
        diagnose("engine.configuration", engine: old.engine, boundDevice: old.boundDevice)
        guard Self.needsRebuild(running: old.engine.isRunning, current: current, bound: old.boundDevice) else { return }
        #endif
        let armed = state.withLock { s -> (Int, AudioFormatSpec)? in
            guard s.engine === old, let format = s.format else { return nil }
            s.engine = nil
            return (s.lease, format)
        }
        guard let (lease, format) = armed else { return }
        if let observer = state.withLock({ s -> ObserverBox? in defer { s.observer = nil }; return s.observer }) {
            NotificationCenter.default.removeObserver(observer.token)
        }
        old.stop()
        // Automatic routing can fall back; an explicitly selected device never opens another microphone.
        var rebuilt: EngineBox?
        do {
            rebuilt = try await launchEngine(format: format, device: device)
        } catch {
            diagnose("engine.restart.failed", engine: old.engine, error: error)
            if Self.mayFallbackToDefault(bound: device, strictDevice: strictDevice) {
                do { rebuilt = try await launchEngine(format: format, device: nil) }
                catch { diagnose("engine.restart.fallback.failed", engine: old.engine, error: error) }
            }
        }
        guard let fresh = rebuilt else {
            router.setSink(nil)
            return
        }
        let kept = state.withLock { s -> Bool in
            guard s.lease == lease else { return false }
            s.engine = fresh
            return true
        }
        if kept {
            #if os(macOS)
            diagnose("engine.restart.succeeded", engine: fresh.engine, boundDevice: fresh.boundDevice)
            #else
            diagnose("engine.restart.succeeded", engine: fresh.engine)
            #endif
            installConfigurationObserver(for: fresh)
            resumeSink.yield()
        } else {
            fresh.stop()
        }
    }

    private func diagnose(_ event: String, engine: AVAudioEngine, boundDevice: UInt32? = nil, error: (any Error)? = nil) {
        guard let onDiagnostic else { return }
        var fields = [
            "requested": device.map(String.init) ?? "default", "boundDevice": boundDevice.map(String.init) ?? "default", "running": String(engine.isRunning),
            "strictDevice": String(strictDevice), "error": error.map { String(describing: $0) } ?? "none",
        ]
        #if os(macOS)
        if let unit = engine.inputNode.audioUnit {
            fields["currentDeviceElement0"] = Self.inputDevice(of: unit, element: 0).map(String.init) ?? "unknown"
            fields["currentDeviceElement1"] = Self.inputDevice(of: unit, element: 1).map(String.init) ?? "unknown"
        }
        #endif
        onDiagnostic(Diagnostic(event: event, fields: fields))
    }

    /// Whether an unavailable pinned input may be replaced by the default input.
    static func mayFallbackToDefault(bound: UInt32?, strictDevice: Bool) -> Bool {
        bound != nil && !strictDevice
    }

    #if os(macOS)
    /// The unit's input element. On the voice-processing unit element 0 is the output (speaker) device, so
    /// binding there put the mic's id on the output side and left the input on the default.
    private static let inputElement: AudioUnitElement = 1

    /// Points the input node's unit at `device` and checks that it took. nil on success.
    private static func bind(_ input: AVAudioInputNode, to device: UInt32) -> MicSourceError? {
        guard let unit = input.audioUnit else { return .deviceNotSelected(device: device, status: 0) }
        // AUHAL is one duplex device: both sides must refer to our aggregate, otherwise AVAudioEngine
        // replaces the input with its own aggregate containing the system-default microphone.
        for element: AudioUnitElement in [0, inputElement] {
            var id = AudioDeviceID(device)
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr, inputDevice(of: unit, element: element) == device else {
                return .deviceNotSelected(device: device, status: status)
            }
        }
        return nil
    }

    /// The device the unit's input runs on.
    private static func inputDevice(of unit: AudioUnit, element: AudioUnitElement = inputElement) -> UInt32? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &id, &size)
        return status == noErr ? id : nil
    }
    #endif

    /// The format to tap the input node with. Bound to a device, the node still reports the format of the
    /// default input it was made on (24 kHz AirPods while the built-in mic runs at 48 kHz), and a tap in that
    /// format is refused, so a plain input takes the device's own format. Voice processing delivers its own.
    static func tapFormat(output: AVAudioFormat, hardware: AVAudioFormat, bound: Bool, voiceProcessing: Bool) -> AVAudioFormat {
        bound && !voiceProcessing ? hardware : output
    }

    /// Whether a configuration change needs a fresh engine. A bound engine posts one change for the bind itself
    /// while it runs on, on its device; rebuilding on that binds again and posts again, without end. It needs a
    /// rebuild once it stopped, or once AVAudioEngine moved it to another device (the default changed).
    static func needsRebuild(running: Bool, current: UInt32?, bound: UInt32?) -> Bool {
        guard let bound else { return true }
        return !running || current != bound
    }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        router.setSink(continuation)
        return stream
    }

    /// Built outside any actor: a closure formed in an isolated context inherits that isolation,
    /// and Swift 6 traps when AVFAudio calls it on the realtime thread.
    nonisolated private static func tapBlock(_ router: TapRouter, _ converter: BufferConverter, _ probe: FirstBufferProbe?) -> AVAudioNodeTapBlock {
        { buffer, _ in
            probe?.observe(buffer)
            if let chunk = converter.convert(buffer) { router.handle(chunk) }
        }
    }
}
