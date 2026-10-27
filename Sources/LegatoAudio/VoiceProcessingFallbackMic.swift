import Foundation
import LegatoCore
import Synchronization

/// The meeting's microphone with a way out of a broken voice-processing unit.
///
/// Voice processing (echo cancellation) can fail to configure on some Bluetooth headsets: starting it throws,
/// or it starts and then delivers digital near-silence. Either way this source carries on without it for the
/// rest of the meeting, on the same chunk stream, and says so through ``notices``:
///
/// - a start that throws with voice processing on is retried with it off;
/// - a start that works is watched by a ``MicSilenceGuard`` for its first seconds; a `silent` verdict stops that
///   microphone and starts a plain one, and ``resumptions`` yields so the meeting fills the gap with silence.
///
/// Resumptions of the underlying microphone (an engine rebuilt after a device change) are passed on too.
/// Dictation's `MicSource` is untouched; only a meeting wraps it. The real failure is hardware-only; the
/// wiring is tested with fake microphones.
public final class VoiceProcessingFallbackMic: ResumableAudioSource {
    public static let notice = "Voice processing didn't work with this device; recording the mic without it."
    public static let restartFailedNotice = "The microphone could not be restarted without voice processing; the rest of it is not recorded."

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
        /// Present while the first seconds of a voice-processing microphone are being judged.
        var watching: MicSilenceGuard?
        var switching = false
    }

    private let state = Mutex(State())
    private let noticeSink: AsyncStream<String>.Continuation
    private let resumeSink: AsyncStream<Void>.Continuation
    private let make: @Sendable (Bool) -> any AudioSource
    private let voiceProcessing: Bool
    private let guardian: MicSilenceGuard

    /// - Parameters:
    ///   - voiceProcessing: whether to try voice processing first.
    ///   - guardian: how long and how quiet counts as a dead microphone.
    ///   - make: builds a microphone with voice processing on or off, one per start and per switch.
    public init(
        voiceProcessing: Bool, guardian: MicSilenceGuard = MicSilenceGuard(),
        make: @escaping @Sendable (Bool) -> any AudioSource
    ) {
        self.voiceProcessing = voiceProcessing
        self.guardian = guardian
        self.make = make
        (notices, noticeSink) = AsyncStream.makeStream(of: String.self)
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// The microphone a meeting uses: Apple's `MicSource`, with voice processing as asked.
    public convenience init(voiceProcessing: Bool) {
        self.init(voiceProcessing: voiceProcessing, make: { MicSource(voiceProcessing: $0) })
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stopCurrent()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let lifecycle = state.withLock { s -> Int in
            s.lifecycle += 1
            s.continuation = continuation
            s.format = format
            s.watching = voiceProcessing ? guardian : nil
            return s.lifecycle
        }
        do {
            do {
                try await launch(voiceProcessing: voiceProcessing, format: format, lifecycle: lifecycle)
            } catch where voiceProcessing && !(error is CancellationError) {
                state.withLock { $0.watching = nil }
                noticeSink.yield(Self.notice)
                try await launch(voiceProcessing: false, format: format, lifecycle: lifecycle)
            }
        } catch {
            await stop()
            throw error
        }
        return stream
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

    /// Starts one microphone and wires it to the stream. Throws `MicSourceError.notArmed`, after stopping the
    /// new microphone, when a stop or restart got there first.
    private func launch(voiceProcessing: Bool, format: AudioFormatSpec, lifecycle: Int) async throws {
        let source = make(voiceProcessing)
        let chunks = try await source.start(format: format)
        let pump = Task { [weak self] in
            for await chunk in chunks { self?.deliver(chunk) }
        }
        let relay = (source as? any ResumableAudioSource).map { resumable in
            let resumptions = resumable.resumptions
            return Task { [weak self] in
                for await _ in resumptions { self?.resumeSink.yield() }
            }
        }
        let kept = state.withLock { s -> Bool in
            guard s.lifecycle == lifecycle else { return false }
            s.inner = source
            s.pump = pump
            s.relay = relay
            return true
        }
        if !kept {
            await source.stop()
            relay?.cancel()
            await pump.value
            throw MicSourceError.notArmed
        }
    }

    /// Forwards a chunk; while the first seconds are being judged, a `silent` verdict starts the switch.
    private func deliver(_ chunk: AudioChunk) {
        let (continuation, verdict) = state.withLock { s -> (AsyncStream<AudioChunk>.Continuation?, MicSilenceGuard.Verdict) in
            guard var watching = s.watching else { return (s.continuation, .working) }
            let verdict = watching.observe(chunk)
            s.watching = verdict == .undecided ? watching : nil
            return (s.continuation, verdict)
        }
        continuation?.yield(chunk)
        if verdict == .silent { Task { await switchToPlainMic() } }
    }

    private func switchToPlainMic() async {
        let taken = state.withLock { s -> (any AudioSource, Task<Void, Never>?, Task<Void, Never>?, AudioFormatSpec, Int)? in
            guard !s.switching, let inner = s.inner, let format = s.format else { return nil }
            s.switching = true
            defer { s.inner = nil; s.pump = nil; s.relay = nil }
            return (inner, s.pump, s.relay, format, s.lifecycle)
        }
        guard let (old, oldPump, oldRelay, format, lifecycle) = taken else { return }
        noticeSink.yield(Self.notice)
        await old.stop()
        oldRelay?.cancel()
        await oldPump?.value // what the old microphone still had reaches the stream first
        do {
            try await launch(voiceProcessing: false, format: format, lifecycle: lifecycle)
            resumeSink.yield()
        } catch is MicSourceError {
            // stopped meanwhile: nothing to report
        } catch {
            noticeSink.yield(Self.restartFailedNotice)
        }
        state.withLock { $0.switching = false }
    }
}
