#if DEBUG
import Foundation
import LegatoCore
import Synchronization

// Scripted stand-ins for the engine, the mic and the audio session, used by the simulator end-to-end
// run (`scripts/e2e/ios-sim.sh`). The simulator has no working SpeechTranscriber and no microphone.
// Debug builds only: none of this is compiled into Release.

/// Emits a fixed text word by word: a volatile result, then the final one, `wordDelay` apart.
/// Like a real engine it keeps its stream open until `finish()` (the audio ended).
final class E2EScriptedEngine: DictationEngine, Sendable {
    let id = "e2e-scripted"

    private struct State {
        var continuation: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation?
        var task: Task<Void, Never>?
        /// A word shown as volatile whose final has not been emitted yet.
        var pending: String?
    }

    private let words: [String]
    private let wordDelay: Duration
    private let state = Mutex(State())

    init(text: String, wordDelay: Duration = .milliseconds(150)) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        self.wordDelay = wordDelay
    }

    func installAssets(locale: Locale?) -> AsyncStream<Double> {
        AsyncStream { $0.finish() }
    }

    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    }

    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream()
        let words = self.words, half = wordDelay / 2
        let task = Task { [weak self] in
            for word in words {
                if Task.isCancelled { return }
                self?.state.withLock { $0.pending = word }
                continuation.yield(TranscriptEvent(text: word, isFinal: false))
                try? await Task.sleep(for: half)
                if Task.isCancelled { return }
                continuation.yield(TranscriptEvent(text: word + " ", isFinal: true))
                self?.state.withLock { $0.pending = nil }
                try? await Task.sleep(for: half)
            }
        }
        state.withLock {
            $0.continuation = continuation
            $0.task = task
            $0.pending = nil
        }
        return stream
    }

    func finish() async throws {
        let (continuation, task) = state.withLock { s in
            defer { s.continuation = nil; s.task = nil }
            return (s.continuation, s.task)
        }
        task?.cancel()
        await task?.value
        // A real engine finalizes what it was still unsure about.
        if let pending = state.withLock({ s in defer { s.pending = nil }; return s.pending }) {
            continuation?.yield(TranscriptEvent(text: pending + " ", isFinal: true))
        }
        continuation?.finish()
    }
}

/// A microphone that produces no audio but follows the real source's lifecycle.
final class E2EFakeAudioSource: AudioSource, Sendable {
    private let stream = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let policy: AudioPolicy

    init(policy: AudioPolicy = .default) { self.policy = policy }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        if let refusal = E2E.refusal(sessionStep: false, policy: policy) {
            E2E.log("audio.start.refused error=\(SystemStartEnvironment.refusalLabel(refusal))")
            throw refusal
        }
        E2E.log("audio.start")
        return makeStream()
    }

    func route() async throws -> AsyncStream<AudioChunk> {
        E2E.log("audio.route")
        return makeStream()
    }

    func detach() async {
        E2E.log("audio.detach")
        stream.withLock { $0?.finish(); $0 = nil }
    }

    func stop() async {
        E2E.log("audio.stop")
        stream.withLock { $0?.finish(); $0 = nil }
    }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (s, c) = AsyncStream<AudioChunk>.makeStream()
        stream.withLock { $0?.finish(); $0 = c }
        return s
    }
}

/// An audio session that does nothing but log.
struct E2ENoopSessionControl: AudioSessionControlling {
    var policy: AudioPolicy = .default
    var supportedPolicies: Set<AudioPolicy> { Set(AudioPolicy.allCases) }

    func activate(_ config: SessionConfig) throws {
        if let refusal = E2E.refusal(sessionStep: true, policy: policy) {
            E2E.log("session.activate.refused error=\(SystemStartEnvironment.refusalLabel(refusal))")
            throw refusal
        }
        E2E.log("session.activate")
    }
    func deactivate() { E2E.log("session.deactivate") }
}
#endif
