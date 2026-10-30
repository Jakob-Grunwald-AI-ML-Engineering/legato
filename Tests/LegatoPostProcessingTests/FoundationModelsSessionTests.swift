#if canImport(FoundationModels)
import Foundation
import FoundationModels
import LegatoCore
import Synchronization
import Testing
@testable import LegatoPostProcessing

/// Records which transcript each underlying session started from and what each turn sent.
private final class TurnLog: Sendable {
    struct State { var created: [Transcript] = []; var prompts: [String] = []; var replies: [String]; var prewarmed = 0; var prefixes: [String?] = [] }
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
    func prewarm(promptPrefix: String?) { log.value.withLock { $0.prewarmed += 1; $0.prefixes.append(promptPrefix) } }
}

private let words: @Sendable (String) async throws -> Int = { $0.split(whereSeparator: \.isWhitespace).count }

private func fakeSession(_ log: TurnLog, budget: Int = 3_000,
                         count: @escaping @Sendable (String) async throws -> Int = words) -> FoundationModelsSession {
    FoundationModelsSession(tokenBudget: budget, count: count, makeTurns: { transcript in
        log.value.withLock { $0.created.append(transcript) }
        return FakeTurns(log: log)
    })
}

private let systemModelAvailable = SystemLanguageModel.default.availability == .available
private let realEnabled = ProcessInfo.processInfo.environment["LEGATO_REAL_ENGINE"] == "1"
    && SystemLanguageModel.default.availability == .available

private struct TestReply: LLMStructuredOutput, Codable, Hashable {
    var sentence: Int
    var text: String
    static var llmSchema: LLMSchema {
        .object(name: "TestReply", properties: [LLMSchemaProperty("sentence", .integer()), LLMSchemaProperty("text", .string())])
    }
}

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
        #expect(try await session.respondStructured([TestReply].self, to: "1: hi") == [TestReply(sentence: 1, text: "Hi.")])
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([TestReply].self, to: "2") }
        // Guided generation carries the schema itself; the prompt is not padded with a JSON instruction.
        #expect(log.value.withLock { $0.prompts.first } == "1: hi")
    }

    @Test func sentenceEditSchemaBuildsAGenerationSchema() throws {
        _ = try FoundationModelsSession.generationSchema(for: [TestReply].llmSchema)
    }

    @Test func invalidStructuredOutputRestoresPendingTextAndRebuildsTheSystemSession() async throws {
        let log = TurnLog(replies: ["not JSON", "Recovered."])
        let session = fakeSession(log)
        try await session.append(.text("Keep this context."))
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([TestReply].self, to: "Structured.") }
        #expect(try await session.respond(to: "Plain.") == "Recovered.")
        let state = log.value.withLock { $0 }
        #expect(state.prompts == ["Keep this context.\n\nStructured.", "Keep this context.\n\nPlain."])
        #expect(state.created.count == 2)
        #expect(!String(describing: state.created.last).contains("not JSON"))
    }

    @Test func closeEndsTheSession() async throws {
        let session = fakeSession(TurnLog(replies: []))
        await session.close()
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "x") }
    }

    @Test(.enabled(if: systemModelAvailable, "needs the Apple on-device model"))
    func backendReleaseEndsTheSession() async throws {
        let backend = FoundationModelsBackend()
        let real = try await backend.makeSession()
        await backend.releaseWarmResources()
        await #expect(throws: LLMSessionError.closed) { try await real.append(.text("x")) }
    }

    @Test func warmOpensTheSystemSessionOnTheHeadAheadOfTheFirstTurn() async throws {
        let log = TurnLog(replies: ["One."])
        let session = fakeSession(log)
        try await session.append(.instructions("Clean."))
        try await session.warm()
        try await session.append(.text("run text"))
        _ = try await session.respond(to: "Go.")
        let state = log.value.withLock { $0 }
        #expect(state.prewarmed == 1)
        #expect(state.created.count == 1)
        #expect(state.created[0].count == 1)  // the instructions only
    }

    @Test func warmPrewarmsThePendingTextAsThePromptPrefix() async throws {
        let log = TurnLog(replies: ["One."])
        let session = fakeSession(log)
        try await session.append(.instructions("Clean."))
        try await session.append(.text("run text"))
        try await session.warm()
        _ = try await session.respond(to: "Go.")
        let state = log.value.withLock { $0 }
        #expect(state.prefixes == ["run text"])
        #expect(state.prompts == ["run text\n\nGo."])  // the prefix the system cached starts the prompt
    }

    @Test func aTrimReopensAndPrewarmsTheRollingSessionOnTheKeptTranscript() async throws {
        let log = TurnLog(replies: ["a", "b", "c", "d"])
        let session = fakeSession(log)
        try await session.append(.instructions("Clean the text."))
        try await session.warm()
        for index in 1...3 { _ = try await session.respond(to: "turn \(index) has several words in it") }
        let before = try await session.usage()
        try await session.trim(keepingSuffix: before.history / 2)
        // Warm again right away (head and kept turns), not on the next run's first turn.
        var state = log.value.withLock { $0 }
        #expect(state.created.count == 2)
        #expect(state.prewarmed == 2)
        _ = try await session.respond(to: "after")
        state = log.value.withLock { $0 }
        #expect(state.created.count == 2)
    }

    @Test func aTrimOfAColdSessionStaysCold() async throws {
        let log = TurnLog(replies: ["a", "b"])
        let session = fakeSession(log)
        try await session.append(.instructions("Clean the text."))
        for index in 1...2 { _ = try await session.respond(to: "turn \(index) has several words in it") }
        try await session.trim(keepingSuffix: 0)
        #expect(log.value.withLock { $0.prewarmed } == 0)
    }

    @Test func theSchemaInThePromptCountsAgainstTheBudget() async throws {
        let characters: @Sendable (String) async throws -> Int = { $0.count }
        let log = TurnLog(replies: [#"[{"sentence": 1, "text": "Hi."}]"#])
        let session = fakeSession(log, count: characters)
        let before = try await session.usage()
        _ = try await session.respondStructured([TestReply].self, to: "1: hi")
        let after = try await session.usage()
        let schema = LLMStructuredDecoding.jsonSchema([TestReply].llmSchema).count
        let turn = "1: hi".count + #"[{"sentence": 1, "text": "Hi."}]"#.count + LLMTranscript.turnOverhead
        #expect(after.history == turn + schema)  // the schema the turn sent
        #expect(after.head == before.head + schema)  // room for the next structured turn's schema
    }

    @Test(.enabled(if: systemModelAvailable, "needs the Apple on-device model"))
    func budgetIsTheWindowLessTheReplyReserve() async throws {
        let session = try await FoundationModelsBackend().makeSession()
        #expect(session.tokenBudget == SystemLanguageModel.default.contextSize - FoundationModelsBackend.replyReserve)
        await session.close()
    }

    @Test(.enabled(if: realEnabled, "set LEGATO_REAL_ENGINE=1 on a Mac with Apple Intelligence"))
    func realStructuredEditsDecode() async throws {
        let session = try await FoundationModelsBackend().makeSession()
        try await session.append(.instructions("You fix spelling. Return one edit per changed sentence."))
        try await session.append(.text("1: Teh cat sat on teh mat."))
        let edits = try await session.respondStructured([TestReply].self, to: "Fix sentence 1.")
        print("FM-PROBE structured: \(edits)")
        #expect(edits.allSatisfy { $0.sentence == 1 })
        await session.close()
    }
}
#endif
