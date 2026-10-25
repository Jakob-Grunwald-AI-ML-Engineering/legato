import AVFAudio
import Foundation
import LegatoCore

/// Gives other audio a moment to stop before the audio session is activated.
///
/// Device logs showed that a background mic start works whenever nothing else plays and fails
/// ('!pla' / 'what') while music plays, and iOS does not let an app pause other audio from the
/// background. The supported route is a Shortcut that pauses the music first (see the "Use with
/// music" help in Settings); pausing is not instant, so `prepare` (which runs right before the session
/// is activated) polls `isOtherAudioPlaying` for up to `maxWait` and then goes ahead regardless:
/// a start that might fail is still better than none.
struct OtherAudioGate: DictationEngine {
    static let pollInterval: Duration = .milliseconds(100)
    static let maxWait: Duration = .milliseconds(1200)

    let engine: any DictationEngine
    let isOtherAudioPlaying: @Sendable () -> Bool
    /// Called only when the gate actually waited: how long, and whether other audio still played.
    let report: @Sendable (_ waitedMilliseconds: Int, _ stillPlaying: Bool) -> Void

    var id: String { engine.id }

    func installAssets(locale: Locale?) -> AsyncStream<Double> {
        engine.installAssets(locale: locale)
    }

    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        let format = try await engine.prepare(locale: locale)
        try await waitForOtherAudio() // last, so the session is activated right after
        return format
    }

    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, any Error> {
        engine.transcribe(input)
    }

    func finish() async throws {
        try await engine.finish()
    }

    /// Throws `CancellationError` when the start is cancelled meanwhile (a press while starting).
    private func waitForOtherAudio() async throws {
        guard isOtherAudioPlaying() else { return }
        let clock = ContinuousClock()
        let start = clock.now
        var playing = true
        while playing, clock.now - start < Self.maxWait {
            try await Task.sleep(for: Self.pollInterval)
            playing = isOtherAudioPlaying()
        }
        report(Int(((clock.now - start) / .milliseconds(1)).rounded()), playing)
    }

    /// The app's reporter: the audio diagnostics (internal builds) and the e2e log (Debug).
    @Sendable
    static func report(waitedMilliseconds: Int, stillPlaying: Bool) {
        #if LEGATO_INTERNAL
        AudioDiagnostics.log("otherAudio.wait", ["waitedMs": waitedMilliseconds, "finalOtherAudioPlaying": stillPlaying])
        #endif
        #if DEBUG
        E2E.log("otherAudio.wait waitedMs=\(waitedMilliseconds) playing=\(stillPlaying)")
        #endif
    }
}
