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
    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: 0) }
    func append(_ chunk: LLMSessionChunk) async throws { if closed { throw LLMSessionError.closed } }
    func respond(to request: String) async throws -> String {
        if closed { throw LLMSessionError.closed }
        return "reply"
    }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        try LLMStructuredDecoding.decode(Output.self, from: "[]")
    }
    func trim(keepingSuffix tokens: Int) async throws {}
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
        await warmup.invalidate()  // joins the retirement the released lease started
        #expect(await model.releases == 1)
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "z") }
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

    @Test func runEndClosesTheRunsSessionsAndReleasesTheirLeases() async throws {
        let model = SessionModel()
        let warmup = try await preparedWarmup(model)
        let sessions = LLMSessionSet()
        let backend = ResourceLeasedBackend(backend: model, owner: warmup, key: "cleanup:local", runSessions: sessions)
        let first = try await backend.makeSession(), second = try await backend.makeSession()
        await warmup.setRequested([], for: .dictation, inBackground: false)
        await sessions.closeAll()
        await warmup.invalidate()
        #expect(await model.releases == 1)
        await #expect(throws: LLMSessionError.closed) { _ = try await first.respond(to: "x") }
        await #expect(throws: LLMSessionError.closed) { _ = try await second.respond(to: "x") }
    }

    @MainActor @Test func aDictationRunLeaseEndsItsSessionsAtRelease() async throws {
        let local = SessionModel(), foundation = SessionModel()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let id = CoreMLModels.qwen3_1_7bID
        try InstallMarker.write(in: LeaseInstaller().installFolder(root: root), id: id, stage: .installed)
        let models = ModelServices(root: root, defaults: defaults, platform: .macOS, installers: [id: LeaseInstaller()],
            resources: ModelServiceResources(speech: .init(key: "speech:test", prewarm: {}, release: {}),
                                             foundation: foundation, coreML: { _, _ in local }))
        SelectionStore(defaults: defaults).set(id, for: .cleanup)
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.enabled = true; settings.backend = .coreML
        try await models.prepareSelectedModels(options: settings.options, inBackground: false)

        let run = try #require(try await models.acquireDictationCleanup(options: settings.options, inBackground: true))
        let backend = try #require(run.resolution.backend)
        let session = try await backend.makeSession()
        #expect(try await session.respond(to: "x") == "reply")
        await run.release()
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "y") }
        await models.releaseSelectedModels()
    }
}

private struct LeaseInstaller: ModelInstaller {
    func installFolder(root: URL) -> URL { root.appending(path: "installed") }
    func isInstalled(root: URL) async -> Bool { true }
    func install(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws { Issue.record("No downloads") }
    func warm(root: URL) async throws {}
}
