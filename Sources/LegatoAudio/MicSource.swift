import AVFAudio
import LegatoCore
import Synchronization

public enum MicSourceError: Error, Sendable, Equatable {
    /// `route()` without a preceding `start(format:)`, or after the engine stopped.
    case notArmed
    /// The input node reported a zero sample rate or channel count (session not ready).
    case invalidInputFormat
    /// No converter from the input format to the requested format.
    case converterUnavailable
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

/// Microphone `AudioSource`. The engine runs for a whole lease; runs attach and detach streams.
public final class MicSource: AudioSource {
    private struct State {
        var engine: EngineBox?
    }

    /// Lets the engine cross into the lock under Swift 6.2's region checks. Safe: once stored, the
    /// engine is only touched by `route()` (reads `isRunning`) and by `stop()` after taking it out.
    private final class EngineBox: @unchecked Sendable {
        let engine: AVAudioEngine
        init(_ engine: AVAudioEngine) { self.engine = engine }
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

    /// 8 attempts, 150 ms apart.
    static let maxAttempts = 8
    static let retryDelay: Duration = .milliseconds(150)

    private let state = Mutex(State())
    private let router = TapRouter()
    private let onAttempt: (@Sendable (Attempt) -> Void)?

    /// - Parameter onAttempt: called after every start attempt, success or failure (diagnostics only).
    public init(onAttempt: (@Sendable (Attempt) -> Void)? = nil) {
        self.onAttempt = onAttempt
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stop()
        // The route can still be settling right after session activation (kAUStartIO 'what', or a
        // zero input sample rate), and an engine that failed to start stays unusable. So every
        // attempt builds a fresh engine, after the session is active (an engine made earlier caches
        // an input format that installTap then rejects), and is gated on a valid input format.
        var lastError: (any Error)?
        for attempt in 0..<Self.maxAttempts {
            if attempt > 0 { try await Task.sleep(for: Self.retryDelay) }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
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
            guard let converter = BufferConverter(from: inFormat, to: format) else {
                report(MicSourceError.converterUnavailable)
                throw MicSourceError.converterUnavailable
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat, block: Self.tapBlock(router, converter))
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
            let box = EngineBox(engine)
            state.withLock { $0.engine = box }
            return makeStream()
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
        let engine = state.withLock { s in
            let e = s.engine
            s.engine = nil
            return e
        }
        guard let engine = engine?.engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        router.setSink(continuation)
        return stream
    }

    /// Built outside any actor: a closure formed in an isolated context inherits that isolation,
    /// and Swift 6 traps when AVFAudio calls it on the realtime thread.
    nonisolated private static func tapBlock(_ router: TapRouter, _ converter: BufferConverter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let chunk = converter.convert(buffer) { router.handle(chunk) }
        }
    }
}
