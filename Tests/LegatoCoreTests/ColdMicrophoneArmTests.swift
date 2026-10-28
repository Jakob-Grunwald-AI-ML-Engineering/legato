import Foundation
import Testing
@testable import LegatoCore

/// A selected recognizer whose native weights are still cold, but whose installed capture format is known.
private struct ColdCaptureEngine: DictationEngine {
    let id = "selected-cold-recognizer"
    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func captureFormat(locale: Locale?) async throws -> AudioFormatSpec { testFormat }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec { throw TestError() }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func finish() async throws {}
}

@MainActor private final class ColdRecognitionReadiness: Readiness {
    func check() async -> ReadinessIssue? { .assetsMissing }
    func checkMicrophone() async -> ReadinessIssue? { nil }
}

@MainActor struct ColdMicrophoneArmTests {
    @Test func installedCaptureFormatArmsWithoutPreparingRecognitionButStartStillPrepares() async throws {
        let log = EventLog(), history = MemoryHistory()
        let session = DictationSession(engine: ColdCaptureEngine(), source: FakeSource(log: log),
            sessionControl: FakeSessionControl(log: log), history: history, linger: .indefinite)
        do { try await session.armLease() }
        catch { Issue.record("Cold recognition must not block a microphone-only lease: \(error)") }
        #expect(session.leaseState == .armed)
        #expect(log.count("activate") == 1)
        await #expect(throws: TestError.self) { try await session.start() }
        await session.endLease()
    }

    @Test func coordinatorChecksMicrophonePrerequisitesWithoutClaimingRecognitionReady() async {
        let log = EventLog(), history = MemoryHistory()
        let coordinator = DictationCoordinator(activity: FakeActivity(log: log), clipboard: FakeClipboard(log: log),
            readiness: ColdRecognitionReadiness(), startEnvironment: FakeStartEnvironment(), history: history,
            makeSession: { policy, linger in
                DictationSession(engine: ColdCaptureEngine(), source: FakeSource(log: log),
                    sessionControl: FakeSessionControl(log: log), history: history, policy: policy, linger: linger)
            })
        #expect(await coordinator.arm(keepAlive: .indefinite) == .armed)
        #expect(log.count("source.start") == 1)
        await coordinator.endKeepAlive()
    }
}
