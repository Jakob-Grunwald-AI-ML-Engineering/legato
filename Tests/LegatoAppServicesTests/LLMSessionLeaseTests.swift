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
    private(set) var sessions: [ScriptedSession] = []
    var availability: LLMAvailability { ready ? .available : .unavailable(reason: "Not ready") }
    func prewarmResources() async throws { ready = true }
    func releaseWarmResources() async {
        ready = false; releases += 1
        for session in sessions { await session.close() }
    }
    func respond(instructions: String, prompt: String) async throws -> String { "stateless" }
    func makeSession() async throws -> any LLMSession {
        guard ready else { throw LLMError.unavailable(reason: "Not ready") }
        let session = ScriptedSession()
        sessions.append(session)
        return session
    }
}

private let head: [LLMSessionChunk] = [.instructions("Clean the dictation."), .example(LLMExample(user: "um hi", assistant: "Hi."))]

private func resource(_ model: SessionModel, key: String = "cleanup:local") -> SelectedModelWarmup.Resource {
    .init(key: key, lifecycle: model, session: .init(head: { head }, make: { try await model.makeSession() }))
}

private func preparedWarmup(_ model: SessionModel, key: String = "cleanup:local") async throws -> SelectedModelWarmup {
    let warmup = SelectedModelWarmup()
    await warmup.setRequested([resource(model, key: key)], for: .dictation, inBackground: false)
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
        for _ in 0..<200 where await model.releases == 0 { try await Task.sleep(for: .milliseconds(10)) }
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

    // MARK: Rolling session (one per prepared cleanup resource, for the app's lifetime)

    @Test func preparingTheModelOpensOneWarmSessionWithTheHead() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let session = try #require(await warmup.rollingSession(key: "cleanup:local") as? ScriptedSession)
        #expect(await session.chunks == head)
        #expect(await session.warmed == 1)
        // Every request gets the same session.
        #expect(await warmup.rollingSession(key: "cleanup:local") === session)
        #expect(await model.sessions.count == 1)
    }

    @Test func runLeasesNeitherOpenNorEndTheRollingSession() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let session = try #require(await warmup.rollingSession(key: "cleanup:local") as? ScriptedSession)
        for run in 1...2 {
            let lease = try await warmup.acquire(keys: ["cleanup:local"], inBackground: true)
            let rolling = try #require(await warmup.rollingSession(key: "cleanup:local"))
            try await rolling.append(.text("run \(run)"))
            _ = try await rolling.respond(to: "Go.")
            await lease.release()
        }
        // Run end left it open, holding both runs' context.
        #expect(await session.closed == false)
        #expect(await session.chunks.suffix(2) == [.text("run 1"), .text("run 2")])
        #expect(await model.sessions.count == 1)
        #expect(await model.releases == 0)
    }

    @Test func memoryPressureEndsTheRollingSessionAndTheNextPreparationOpensANewOne() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let first = try #require(await warmup.rollingSession(key: "cleanup:local") as? ScriptedSession)
        await warmup.invalidate()
        #expect(await first.closed)
        #expect(await warmup.rollingSession(key: "cleanup:local") == nil)
        await warmup.setRequested([resource(model)], for: .dictation, inBackground: false)
        try await warmup.prepare(keys: ["cleanup:local"], inBackground: false)
        let second = try #require(await warmup.rollingSession(key: "cleanup:local") as? ScriptedSession)
        #expect(second !== first)
        #expect(await second.warmed == 1)
    }

    @Test func aModelChangeOrDeletionEndsTheRollingSession() async throws {
        let model = SessionModel(), other = SessionModel()
        let warmup = try await preparedWarmup(model)
        let session = try #require(await warmup.rollingSession(key: "cleanup:local") as? ScriptedSession)
        await warmup.setRequested([resource(other, key: "cleanup:other")], for: .dictation, inBackground: false)
        try await warmup.prepare(keys: ["cleanup:other"], inBackground: false)
        for _ in 0..<200 where await !session.closed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await session.closed)

        let next = try #require(await warmup.rollingSession(key: "cleanup:other") as? ScriptedSession)
        await warmup.revoke(key: "cleanup:other")  // the model was deleted
        for _ in 0..<200 where await !next.closed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await next.closed)
    }

    @Test func aResourceWithoutASessionSourceHasNoRollingSession() async throws {
        let model = SessionModel()
        let warmup = SelectedModelWarmup()
        await warmup.setRequested([.init(key: "plain", lifecycle: model)], for: .dictation, inBackground: false)
        try await warmup.prepare(keys: ["plain"], inBackground: false)
        #expect(await warmup.rollingSession(key: "plain") == nil)
    }

    @MainActor @Test func dictationRunsShareTheRollingSessionAndRunEndKeepsIt() async throws {
        let local = SessionModel(), foundation = SessionModel()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let id = CoreMLModels.qwen3_1_7bID
        try InstallMarker.write(in: LeaseInstaller().installFolder(root: root), id: id, stage: .installed)
        let models = ModelServices(root: root, defaults: defaults, platform: .macOS, installers: [id: LeaseInstaller()],
            resources: ModelServiceResources(speech: .init(key: "speech:test", prewarm: {}, release: {}),
                                             foundation: foundation, coreML: { _, _ in local }))
        models.rollingSessionHead = { [.instructions("Agent head")] }
        SelectionStore(defaults: defaults).set(id, for: .cleanup)
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.enabled = true; settings.backend = .coreML
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)

        let rolling = try #require(await models.rollingCleanupSession(for: .coreML) as? ScriptedSession)
        #expect(await rolling.chunks == [.instructions("Agent head")])
        #expect(await rolling.warmed == 1)
        for _ in 1...2 {
            let run = try #require(try await models.acquireDictationCleanup(options: settings.options, inBackground: true))
            let session = try #require(await models.rollingCleanupSession(for: .coreML))
            #expect(session === rolling)
            #expect(try await session.respond(to: "x") == "reply")
            await run.release()
            #expect(await rolling.closed == false)
        }
        await models.releaseSelectedModels()
        #expect(await rolling.closed)
    }
}

private struct LeaseInstaller: ModelInstaller {
    func installFolder(root: URL) -> URL { root.appending(path: "installed") }
    func isInstalled(root: URL) async -> Bool { true }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws { Issue.record("No downloads") }
    func warm(root: URL) async throws {}
}
