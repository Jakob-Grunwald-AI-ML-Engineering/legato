import Foundation
import LegatoCore
import Synchronization

/// What the meeting mic can ask about the input devices around it (Core Audio on the Mac; nothing in tests or on iOS).
public struct MicDevices: Sendable {
    /// The system default input device, if known.
    public var defaultInput: @Sendable () -> UInt32?
    /// A device's name, for notices.
    public var name: @Sendable (UInt32) -> String?
    /// The input device the call app records from now, if a call app is running.
    public var callInput: @Sendable () -> UInt32?

    public init(
        defaultInput: @escaping @Sendable () -> UInt32?, name: @escaping @Sendable (UInt32) -> String?,
        callInput: @escaping @Sendable () -> UInt32?
    ) {
        self.defaultInput = defaultInput
        self.name = name
        self.callInput = callInput
    }

    public static let unknown = MicDevices(defaultInput: { nil }, name: { _ in nil }, callInput: { nil })
}

/// The meeting's microphone: on the call app's input device, watched for a dead input, with a way out of a
/// broken voice-processing unit. Everything happens on one chunk stream; what the user should know comes
/// through ``notices``, and every replaced microphone makes ``resumptions`` yield so the meeting fills the gap.
///
/// - **Device.** It records from `device` (nil: the system default input) and moves to the device given to
///   ``follow(device:)`` (the call app's, which the Mac app polls). A device the microphone cannot be bound to
///   is reported by name and the default input records instead; that device is not tried again with the same
///   voice-processing setting, however often it is followed.
/// - **Dead input.** After every start and restart a ``MicSilenceGuard`` judges the first seconds.
///   A `silent` plain microphone is reported by name, and moved to the call app's device when that differs.
/// - **Voice processing** can fail to configure on some Bluetooth headsets: starting it throws, or it starts
///   and delivers near-silence. Either way this source carries on without it for the rest of the meeting.
///
/// Resumptions of the underlying microphone (an engine rebuilt after a device change) are passed on too, and
/// re-arm the guard. Dictation's `MicSource` is untouched; only a meeting wraps it. The real failures are
/// hardware-only; the wiring is tested with fake microphones.
public final class VoiceProcessingFallbackMic: ResumableAudioSource {
    public static let notice = "Voice processing didn't work with this device; recording the mic without it."
    public static let restartFailedNotice = "The microphone could not be restarted; the rest of it is not recorded."

    /// The notice for a dead plain microphone. `call` is the call app's device when it is another one.
    public static func deadMicNotice(mic: String?, call: String?) -> String {
        let yours = mic.map { "Your mic (\($0))" } ?? "Your mic"
        if let call { return "\(yours) hears nothing — the call uses \(call)" }
        return "\(yours) hears nothing — check the input in System Settings → Sound"
    }

    /// The notice for a device the microphone could not be bound to.
    public static func deviceNotSelectedNotice(_ name: String?) -> String {
        "Couldn't record from \(name ?? "the call's mic") — recording from the default input instead"
    }

    /// What to tell the user, one string per event. One consumer.
    public let notices: AsyncStream<String>
    public let resumptions: AsyncStream<Void>

    private struct State {
        var inner: (any AudioSource)?
        var pump: Task<Void, Never>?
        var relay: Task<Void, Never>?
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var format: AudioFormatSpec?
        /// Bumped by every start and stop, so a switch that lost the race to either backs out.
        var lifecycle = 0
        /// Present while the first seconds after a (re)start are being judged.
        var watching: MicSilenceGuard?
        var switching = false
        /// What the running microphone was started with.
        var voiceProcessingOn = false
        var device: UInt32?
        /// The device to record from; a switch in progress moves on to it afterwards.
        var wanted: UInt32?
        /// The last device that could not be bound, and with which voice-processing setting.
        var refused: (device: UInt32, voiceProcessing: Bool)?

        /// The device to start a microphone on: the wanted one, unless it was refused with this setting.
        func target(voiceProcessing: Bool) -> UInt32? {
            if let refused, refused.device == wanted, refused.voiceProcessing == voiceProcessing { return nil }
            return wanted
        }
    }

    private let state: Mutex<State>
    private let noticeSink: AsyncStream<String>.Continuation
    private let resumeSink: AsyncStream<Void>.Continuation
    private let make: @Sendable (Bool, UInt32?) -> any AudioSource
    private let voiceProcessing: Bool
    private let guardian: MicSilenceGuard
    private let devices: MicDevices

    /// - Parameters:
    ///   - voiceProcessing: whether to try voice processing first.
    ///   - guardian: how long and how quiet counts as a dead microphone.
    ///   - device: the input device to record from; nil is the system default.
    ///   - devices: names, the default input and the call app's input, for the dead-mic notice and switch.
    ///   - makeMic: builds a microphone with voice processing on or off on a device, one per start and per switch.
    public init(
        voiceProcessing: Bool, guardian: MicSilenceGuard = MicSilenceGuard(), device: UInt32? = nil,
        devices: MicDevices = .unknown, makeMic: @escaping @Sendable (Bool, UInt32?) -> any AudioSource
    ) {
        self.voiceProcessing = voiceProcessing
        self.guardian = guardian
        self.devices = devices
        self.make = makeMic
        state = Mutex(State(wanted: device))
        (notices, noticeSink) = AsyncStream.makeStream(of: String.self)
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Without devices: the microphone is always the system default.
    public convenience init(
        voiceProcessing: Bool, guardian: MicSilenceGuard = MicSilenceGuard(),
        make: @escaping @Sendable (Bool) -> any AudioSource
    ) {
        self.init(voiceProcessing: voiceProcessing, guardian: guardian, makeMic: { vp, _ in make(vp) })
    }

    /// The microphone a meeting uses: Apple's `MicSource`, with voice processing as asked, on `device`.
    public convenience init(voiceProcessing: Bool, device: UInt32? = nil, devices: MicDevices = .unknown) {
        self.init(
            voiceProcessing: voiceProcessing, device: device, devices: devices,
            makeMic: { MicSource(voiceProcessing: $0, device: $1) })
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stopCurrent()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (lifecycle, device) = state.withLock { s -> (Int, UInt32?) in
            s.lifecycle += 1
            s.continuation = continuation
            s.format = format
            return (s.lifecycle, s.target(voiceProcessing: voiceProcessing))
        }
        do {
            do {
                try await launch(voiceProcessing: voiceProcessing, device: device, format: format, lifecycle: lifecycle)
            } catch where voiceProcessing && !(error is CancellationError) {
                noticeSink.yield(Self.notice)
                let device = state.withLock { $0.target(voiceProcessing: false) }
                try await launch(voiceProcessing: false, device: device, format: format, lifecycle: lifecycle)
            }
        } catch {
            await stop()
            throw error
        }
        return stream
    }

    /// Records from `device` from now on (the call app's input). The running microphone is replaced on the
    /// same stream unless it already uses it (or could not be bound to it); before a start, the start uses it.
    public func follow(device: UInt32) async {
        let move = state.withLock { s -> Bool in
            s.wanted = device
            return s.inner != nil && !s.switching && s.device != s.target(voiceProcessing: s.voiceProcessingOn)
        }
        if move { await switchMic(voiceProcessing: nil, notice: nil) }
    }

    public func route() async throws -> AsyncStream<AudioChunk> { throw MicSourceError.notArmed }
    public func detach() async {}

    public func stop() async {
        await stopCurrent()
        noticeSink.finish()
        resumeSink.finish()
    }

    // MARK: Internals

    private func stopCurrent() async {
        let (inner, pump, relay, continuation) = state.withLock { s in
            defer {
                s.inner = nil; s.pump = nil; s.relay = nil; s.continuation = nil; s.format = nil
                s.watching = nil; s.lifecycle += 1
            }
            return (s.inner, s.pump, s.relay, s.continuation)
        }
        await inner?.stop()
        relay?.cancel()
        await pump?.value
        continuation?.finish()
    }

    /// Starts one microphone, wires it to the stream and arms the guard. A device it cannot be bound to is
    /// reported and remembered, and the default input is started instead. Throws `MicSourceError.notArmed`,
    /// after stopping the new microphone, when a stop or restart got there first.
    private func launch(voiceProcessing: Bool, device: UInt32?, format: AudioFormatSpec, lifecycle: Int) async throws {
        let source = make(voiceProcessing, device)
        let chunks: AsyncStream<AudioChunk>
        do {
            chunks = try await source.start(format: format)
        } catch MicSourceError.deviceNotSelected(let refused, _) where device != nil {
            state.withLock { $0.refused = (refused, voiceProcessing) }
            noticeSink.yield(Self.deviceNotSelectedNotice(devices.name(refused)))
            try await launch(voiceProcessing: voiceProcessing, device: nil, format: format, lifecycle: lifecycle)
            return
        }
        let pump = Task { [weak self] in
            for await chunk in chunks { self?.deliver(chunk) }
        }
        let relay = (source as? any ResumableAudioSource).map { resumable in
            let resumptions = resumable.resumptions
            return Task { [weak self] in
                for await _ in resumptions {
                    self?.rearm()
                    self?.resumeSink.yield()
                }
            }
        }
        let kept = state.withLock { s -> Bool in
            guard s.lifecycle == lifecycle else { return false }
            s.inner = source
            s.pump = pump
            s.relay = relay
            s.voiceProcessingOn = voiceProcessing
            s.device = device
            s.watching = guardian
            return true
        }
        if !kept {
            await source.stop()
            relay?.cancel()
            await pump.value
            throw MicSourceError.notArmed
        }
    }

    /// The underlying microphone restarted (a new engine, maybe a new device): judge it afresh.
    private func rearm() {
        state.withLock { s in
            guard s.inner != nil, !s.switching else { return }
            s.watching = guardian
        }
    }

    /// Forwards a chunk; while the first seconds are being judged, a `silent` verdict acts on it.
    private func deliver(_ chunk: AudioChunk) {
        typealias Judged = (AsyncStream<AudioChunk>.Continuation?, MicSilenceGuard.Verdict, Bool)
        let (continuation, verdict, voiceProcessingOn) = state.withLock { s -> Judged in
            guard var watching = s.watching else { return (s.continuation, .working, s.voiceProcessingOn) }
            let verdict = watching.observe(chunk)
            s.watching = verdict == .undecided ? watching : nil
            return (s.continuation, verdict, s.voiceProcessingOn)
        }
        continuation?.yield(chunk)
        guard verdict == .silent else { return }
        if voiceProcessingOn {
            Task { await switchMic(voiceProcessing: false, notice: Self.notice) }
        } else {
            Task { await reportDeadMic() }
        }
    }

    /// A plain microphone hears nothing: say which, and move to the call app's device when it is another one.
    private func reportDeadMic() async {
        let current = state.withLock { $0.device } ?? devices.defaultInput()
        let call = devices.callInput().flatMap { $0 == current ? nil : $0 }
        noticeSink.yield(Self.deadMicNotice(
            mic: current.flatMap(devices.name), call: call.map { devices.name($0) ?? "another mic" }))
        guard let call else { return }
        await follow(device: call)
    }

    /// Replaces the running microphone with one on the wanted device, on the same stream.
    /// - Parameter voiceProcessing: nil keeps what the running one has.
    private func switchMic(voiceProcessing: Bool?, notice: String?) async {
        typealias Taken = (any AudioSource, Task<Void, Never>?, Task<Void, Never>?, AudioFormatSpec, Int, Bool, UInt32?)
        let taken = state.withLock { s -> Taken? in
            guard !s.switching, let inner = s.inner, let format = s.format else { return nil }
            s.switching = true
            defer { s.inner = nil; s.pump = nil; s.relay = nil; s.watching = nil }
            let vp = voiceProcessing ?? s.voiceProcessingOn
            return (inner, s.pump, s.relay, format, s.lifecycle, vp, s.target(voiceProcessing: vp))
        }
        guard let (old, oldPump, oldRelay, format, lifecycle, vp, device) = taken else { return }
        if let notice { noticeSink.yield(notice) }
        await old.stop()
        oldRelay?.cancel()
        await oldPump?.value // what the old microphone still had reaches the stream first
        do {
            try await launch(voiceProcessing: vp, device: device, format: format, lifecycle: lifecycle)
            resumeSink.yield()
        } catch MicSourceError.notArmed {
            // stopped meanwhile: nothing to report
        } catch {
            noticeSink.yield(Self.restartFailedNotice)
        }
        // A device followed while this switch ran.
        let again = state.withLock { s -> Bool in
            s.switching = false
            return s.inner != nil && s.device != s.target(voiceProcessing: s.voiceProcessingOn)
        }
        if again { await switchMic(voiceProcessing: nil, notice: nil) }
    }
}
