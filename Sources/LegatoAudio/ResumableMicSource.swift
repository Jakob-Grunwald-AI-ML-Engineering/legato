import Foundation
import LegatoCore
import Synchronization

/// One microphone stream that survives engine restarts: an interruption or a route change (AirPods) stops
/// the `AVAudioEngine`, and ``restart()`` builds a fresh one behind the same stream, so the meeting's session
/// keeps reading it. After a restart it reports a ``resumptions`` value; the session fills the time the mic
/// did not deliver with silence, which keeps the recording on the meeting's timeline.
///
/// A `stop()` that arrives while a restart is starting the new engine wins: the new engine is stopped
/// again and the restart throws ``MicSourceError/notArmed``, so no microphone is left running.
public final class ResumableMicSource: ResumableAudioSource {
    private struct State {
        var inner: (any AudioSource)?
        var pump: Task<Void, Never>?
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var format: AudioFormatSpec?
        /// Bumped by every start and stop, so a restart that lost the race to either backs out.
        var generation = 0
    }

    public let resumptions: AsyncStream<Void>
    private let resumeSink: AsyncStream<Void>.Continuation
    private let state = Mutex(State())
    private let make: @Sendable () -> any AudioSource

    /// - Parameter make: builds a fresh microphone, one per start and per restart.
    public init(make: @escaping @Sendable () -> any AudioSource) {
        self.make = make
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        let inner = make()
        let chunks = try await inner.start(format: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        state.withLock {
            $0.inner = inner
            $0.continuation = continuation
            $0.format = format
            $0.generation += 1
        }
        pump(chunks)
        return stream
    }

    /// Replaces the engine with a fresh one. Throws when the new engine does not start; the stream stays
    /// open, and calling again retries.
    public func restart() async throws {
        let (old, oldPump, format, generation) = state.withLock { s -> ((any AudioSource)?, Task<Void, Never>?, AudioFormatSpec?, Int) in
            defer { s.inner = nil; s.pump = nil }
            return (s.inner, s.pump, s.format, s.generation)
        }
        guard let format else { throw MicSourceError.notArmed }
        await old?.stop()
        await oldPump?.value // what the old engine still had reaches the stream first
        let inner = make()
        let chunks = try await inner.start(format: format)
        let current = state.withLock { s -> Bool in
            guard s.generation == generation, s.format != nil else { return false }
            s.inner = inner
            return true
        }
        guard current else {
            await inner.stop() // the meeting stopped while the new engine was starting
            throw MicSourceError.notArmed
        }
        pump(chunks)
        resumeSink.yield()
    }

    private func pump(_ chunks: AsyncStream<AudioChunk>) {
        let task = Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                state.withLock { $0.continuation }?.yield(chunk)
            }
        }
        state.withLock { $0.pump = task }
    }

    public func route() async throws -> AsyncStream<AudioChunk> { throw MicSourceError.notArmed }
    public func detach() async {}

    public func stop() async {
        let (inner, pump, continuation) = state.withLock { s -> ((any AudioSource)?, Task<Void, Never>?, AsyncStream<AudioChunk>.Continuation?) in
            defer { s.inner = nil; s.pump = nil; s.continuation = nil; s.format = nil; s.generation += 1 }
            return (s.inner, s.pump, s.continuation)
        }
        await inner?.stop()
        await pump?.value
        continuation?.finish()
        resumeSink.finish()
    }
}
