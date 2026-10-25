import Foundation

/// A microphone-like producer of audio. The mic is armed once per lease and reused across runs.
public protocol AudioSource: Sendable {
    /// Arms the source (starts the mic) and returns the first run's chunk stream.
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk>

    /// Within an armed lease: ends the previous run's stream and returns a fresh one without restarting the mic.
    func route() async throws -> AsyncStream<AudioChunk>

    /// Ends the current run's stream but keeps the mic armed (lease stays alive).
    func detach() async

    /// Stops the mic and ends any stream. Ends the lease.
    func stop() async
}
