import Foundation
import LegatoCore
import LegatoCoreML
import LegatoModels
import Synchronization
import Testing
@testable import LegatoAppServices

private actor ScriptedSession: LLMSession {
    nonisolated let tokenBudget = 100
    private(set) var closed = false
    private(set) var chunks: [LLMSessionChunk] = []
    private(set) var warmed = 0
    private(set) var trims: [Int] = []
    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: 0) }
    func append(_ chunk: LLMSessionChunk) async throws {
        if closed { throw LLMSessionError.closed }
        chunks.append(chunk)
    }
    func warm() async throws { warmed += 1 }
    func respond(to request: String) async throws -> String {
        if closed { throw LLMSessionError.closed }
        return "reply"
    }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        try LLMStructuredDecoding.decode(Output.self, from: "[]")
    }
    func trim(keepingSuffix tokens: Int) async throws { trims.append(tokens) }
    func close() async { closed = true }
}

/// A prepared native model: sessions it hands out end when its resources are released.
private actor SessionModel: LLMBackend, ModelResourceLifecycle {
    nonisolated let id = "local"
    nonisolated let maxPromptCharacters: Int? = nil
    private(set) var ready = false
    private(set) var releases = 0
    nonisolated let releaseEvents: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    init() { (releaseEvents, releaseContinuation) = AsyncStream.makeStream() }
    private(set) var sessions: [ScriptedSession] = []
    var availability: LLMAvailability { ready ? .available : .unavailable(reason: "Not ready") }
    func prewarmResources() async throws { ready = true }
    func releaseWarmResources() async {
        ready = false; releases += 1
        for session in sessions { await session.close() }
        releaseContinuation.yield(())
    }
    func respond(instructions: String, prompt: String) async throws -> String { "stateless" }
    func makeSession() async throws -> any LLMSession {
        guard ready else { throw LLMError.unavailable(reason: "Not ready") }
        let session = ScriptedSession()
        sessions.append(session)
        return session
    }
}

private func preparedWarmup(_ model: SessionModel, key: String = "cleanup:local") async throws -> SelectedModelWarmup {
    let warmup = SelectedModelWarmup()
    await warmup.setRequested([.init(key: key, lifecycle: model)], for: .dictation, inBackground: false)
    try await warmup.prepare(keys: [key], inBackground: false)
    return warmup
}

@Suite(.timeLimit(.minutes(1)))
struct LLMSessionLeaseTests {
    @Test func aSessionHoldsTheResourceUntilItCloses() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let backend = ResourceLeasedBackend(backend: model, owner: warmup, key: "cleanup:local")
        let session = try await backend.makeSession()
        #expect(try await session.respond(to: "x") == "reply")

        // The selection moves on mid-run: the session's lease keeps the model it was admitted on.
        await warmup.setRequested([], for: .dictation, inBackground: false)
        #expect(await model.releases == 0)
        #expect(try await session.respond(to: "y") == "reply")

        await session.close()
        // Closing released the lease, and with it the retired model, before anything else releases it.
        #expect(await model.releases == 1)
        await warmup.invalidate()
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "z") }
    }

    @Test func aSessionDroppedWithoutClosingReleasesItsLease() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let backend = ResourceLeasedBackend(backend: model, owner: warmup, key: "cleanup:local")
        do { _ = try await backend.makeSession() }  // dropped, never closed
        await warmup.setRequested([], for: .dictation, inBackground: false)
        // The dropped session's lease ends with it, so the deselected model is released without invalidate().
        var releases = model.releaseEvents.makeAsyncIterator()
        let released = await releases.next()
        #expect(released != nil)
        #expect(await model.releases == 1)
    }

    @Test func aSessionNeverColdLoads() async throws {
        let model = SessionModel()
        let warmup = SelectedModelWarmup()
        await warmup.setRequested([.init(key: "cleanup:local", lifecycle: model)], for: .dictation, inBackground: true)
        let backend = ResourceLeasedBackend(backend: model, owner: warmup, key: "cleanup:local")
        await #expect(throws: LLMError.self) { _ = try await backend.makeSession() }
        #expect(await model.ready == false)
    }

    @Test func memoryPressureEndsAnOpenSession() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let session = try await ResourceLeasedBackend(backend: model, owner: warmup, key: "cleanup:local").makeSession()
        await warmup.invalidate()
        #expect(await model.releases == 1)
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "x") }
        await session.close()  // a late close after the pressure release is harmless
    }

}
