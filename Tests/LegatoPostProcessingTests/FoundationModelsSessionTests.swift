#if canImport(FoundationModels)
import Foundation
import FoundationModels
import LegatoCore
import Synchronization
import Testing
@testable import LegatoPostProcessing

/// Records which transcript each underlying session started from and what each turn sent.
private final class TurnLog: Sendable {
    struct State { var created: [Transcript] = []; var prompts: [String] = []; var replies: [String] }
    let value: Mutex<State>
    init(replies: [String]) { value = Mutex(State(replies: replies)) }
}

private final class FakeTurns: FoundationModelsTurning, @unchecked Sendable {
    let log: TurnLog
    init(log: TurnLog) { self.log = log }
    private func next(_ prompt: String) -> String {
        log.value.withLock { $0.prompts.append(prompt); return $0.replies.isEmpty ? "More" : $0.replies.removeFirst() }
    }
    func respond(to prompt: String) async throws -> String { next(prompt) }
    func respondJSON(to prompt: String, schema: GenerationSchema) async throws -> String { next(prompt) }
}

private let words: @Sendable (String) async throws -> Int = { $0.split(whereSeparator: \.isWhitespace).count }

private func fakeSession(_ log: TurnLog, budget: Int = 3_000) -> FoundationModelsSession {
    FoundationModelsSession(tokenBudget: budget, count: words, makeTurns: { transcript in
        log.value.withLock { $0.created.append(transcript) }
        return FakeTurns(log: log)
    })
}

private let realEnabled = ProcessInfo.processInfo.environment["LEGATO_REAL_ENGINE"] == "1"
    && SystemLanguageModel.default.availability == .available

struct FoundationModelsSessionTests {
    @Test func oneSystemSessionServesEveryTurn() async throws {
        let log = TurnLog(replies: ["One.", "Two."])
        let session = fakeSession(log)
        try await session.append(.instructions("Clean."))
        try await session.append(.example(LLMExample(user: "um hi", assistant: "Hi.")))
        try await session.append(.text("first"))
        #expect(try await session.respond(to: "Go.") == "One.")
        try await session.append(.text("second"))
        #expect(try await session.respond(to: "Go.") == "Two.")
        let state = log.value.withLock { $0 }
        #expect(state.created.count == 1)
        #expect(state.prompts == ["first\n\nGo.", "second\n\nGo."])
        // The session starts from the instructions and the examples as turns.
        #expect(state.created[0].count == 3)
    }

    @Test func trimStartsAFreshSystemSessionFromTheKeptTranscript() async throws {
        let log = TurnLog(replies: ["a", "b", "c", "d"])
        let session = fakeSession(log)
        try await session.append(.instructions("Clean the text."))
        for index in 1...3 { _ = try await session.respond(to: "turn \(index) has several words in it") }
        let before = try await session.usage()
        try await session.trim(keepingSuffix: before.history / 2)
        #expect(try await session.usage().history <= before.history / 2)
        _ = try await session.respond(to: "after")
        let created = log.value.withLock { $0.created }
        #expect(created.count == 2)
        // Instructions plus the kept turns (prompt + response each), and nothing of the dropped first turn.
        let rebuilt = created[1]
        #expect(rebuilt.count >= 3 && (rebuilt.count - 1) % 2 == 0)
        #expect(!String(describing: rebuilt).contains("turn 1 has"))
        #expect(String(describing: rebuilt).contains("turn 3 has"))
    }

    @Test func structuredRepliesUseGuidedGenerationAndStillDecodeStrictly() async throws {
        let log = TurnLog(replies: [#"[{"sentence": 1, "text": "Hi."}]"#, #"[{"sentence": "x"}]"#])
        let session = fakeSession(log)
        #expect(try await session.respondStructured([SentenceEdit].self, to: "1: hi") == [SentenceEdit(sentence: 1, text: "Hi.")])
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([SentenceEdit].self, to: "2") }
        // Guided generation carries the schema itself; the prompt is not padded with a JSON instruction.
        #expect(log.value.withLock { $0.prompts.first } == "1: hi")
    }

    @Test func sentenceEditSchemaBuildsAGenerationSchema() throws {
        _ = try FoundationModelsSession.generationSchema(for: [SentenceEdit].llmSchema)
    }

    @Test func closeAndBackendReleaseEndTheSession() async throws {
        let session = fakeSession(TurnLog(replies: []))
        await session.close()
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "x") }

        let backend = FoundationModelsBackend()
        guard SystemLanguageModel.default.availability == .available else { return }
        let real = try await backend.makeSession()
        await backend.releaseWarmResources()
        await #expect(throws: LLMSessionError.closed) { try await real.append(.text("x")) }
    }

    @Test func budgetIsTheWindowLessTheReplyReserve() async throws {
        guard SystemLanguageModel.default.availability == .available else { return }
        let session = try await FoundationModelsBackend().makeSession()
        #expect(session.tokenBudget == SystemLanguageModel.default.contextSize - FoundationModelsBackend.replyReserve)
        await session.close()
    }

    @Test(.enabled(if: realEnabled, "set LEGATO_REAL_ENGINE=1 on a Mac with Apple Intelligence"))
    func realStructuredEditsDecode() async throws {
        let session = try await FoundationModelsBackend().makeSession()
        try await session.append(.instructions("You fix spelling. Return one edit per changed sentence."))
        try await session.append(.text("1: Teh cat sat on teh mat."))
        let edits = try await session.respondStructured([SentenceEdit].self, to: "Fix sentence 1.")
        print("FM-PROBE structured: \(edits)")
        #expect(edits.allSatisfy { $0.sentence == 1 })
        await session.close()
    }
}
#endif
