import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAppServices

@Suite(.timeLimit(.minutes(1))) @MainActor struct SessionProbeBackendTests {
    @Test func harbourMeasurementsCloseEverySessionAndKeepEventsTextFree() async throws {
        let backend = ProbeBackend()
        var measurements: [SessionProbeMeasurement] = [], gaps: [Duration] = []
        let runner = SessionProbeMeasurements(now: { 1 }, sleep: { gaps.append($0) })
        try await runner.run(.init(id: "fake", backend: backend, measuresKickstart: true)) { measurements.append($0) }
        #expect(measurements.map(\.turn) == ["1", "2", "2.fresh", "kickstart.head", "kickstart.warm", "kickstart.warmPrefix", "kickstart.cold"])
        let replay = try #require(measurements.first { $0.turn == "2.fresh" })
        #expect(replay.replyEqual == true)
        #expect(measurements.first?.promptTokens == 40)
        #expect(measurements.first?.prefilledTokens == 3)
        #expect(measurements.first?.prefillMs == 2)
        #expect(gaps == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(await backend.created == 5)
        #expect(await backend.openSessions == 0)
        let encoded = try String(decoding: JSONEncoder().encode(measurements), as: UTF8.self)
        #expect(!encoded.contains("timber"))
        #expect(!encoded.contains("harbour master"))
    }
    @Test func failedMeasurementStillClosesNativeSession() async throws {
        let backend = ProbeBackend(); await backend.setFailTurn()
        await #expect(throws: LLMError.self) {
            try await SessionProbeMeasurements(sleep: { _ in }).run(.init(id: "fake", backend: backend, measuresKickstart: false)) { _ in }
        }
        #expect(await backend.created == 1)
        #expect(await backend.openSessions == 0)
    }
    @Test func cancellationDuringKickstartClosesItsSessionBeforeReturning() async throws {
        let entered = ProbeSignal(), release = ProbeSignal(), backend = ProbeBackend()
        let runner = SessionProbeMeasurements(sleep: { _ in entered.open(); await release.wait(); try Task.checkCancellation() })
        let work = Task { try await runner.run(.init(id: "fake", backend: backend, measuresKickstart: true)) { _ in } }
        await entered.wait()
        work.cancel(); release.open()
        switch await work.result {
        case .success: Issue.record("Cancelled kickstart must fail")
        case .failure(let error): #expect(error is CancellationError)
        }
        #expect(await backend.created == 3)
        #expect(await backend.openSessions == 0)
    }
}
