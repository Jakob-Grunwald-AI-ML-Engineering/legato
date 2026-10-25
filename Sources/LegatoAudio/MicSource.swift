import AVFAudio
import LegatoCore
import Synchronization

public enum MicSourceError: Error, Sendable, Equatable {
    /// `route()` without a preceding `start(format:)`.
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
        var engine: AVAudioEngine?
    }

    private let state = Mutex(State())
    private let router = TapRouter()

    public init() {}

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stop()
        // Fresh engine, created after the session is active: an engine made earlier caches an
        // input format that installTap then rejects.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw MicSourceError.invalidInputFormat }
        guard let converter = BufferConverter(from: inFormat, to: format) else { throw MicSourceError.converterUnavailable }

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat, block: Self.tapBlock(router, converter))
        engine.prepare()
        do {
            try await Self.startWithRetry(engine)
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        state.withLock { $0.engine = engine }
        return makeStream()
    }

    public func route() async throws -> AsyncStream<AudioChunk> {
        guard state.withLock({ $0.engine != nil }) else { throw MicSourceError.notArmed }
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
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        router.setSink(continuation)
        return stream
    }

    /// The route can still be settling right after session activation (kAUStartIO 'what').
    private static func startWithRetry(_ engine: AVAudioEngine) async throws {
        var lastError: (any Error)?
        for attempt in 0..<8 {
            do {
                try engine.start()
                return
            } catch {
                lastError = error
                if attempt < 7 { try await Task.sleep(for: .milliseconds(150)) }
            }
        }
        throw lastError ?? MicSourceError.invalidInputFormat
    }

    /// Built outside any actor: a closure formed in an isolated context inherits that isolation,
    /// and Swift 6 traps when AVFAudio calls it on the realtime thread.
    nonisolated private static func tapBlock(_ router: TapRouter, _ converter: BufferConverter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let chunk = converter.convert(buffer) { router.handle(chunk) }
        }
    }
}
