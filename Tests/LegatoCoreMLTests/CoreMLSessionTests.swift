import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoCoreML

/// A tokenizer-free driver: one token per Unicode scalar, so prefixes are easy to reason about. It records
/// every generation's tokens and the prefix it was told to reuse, and keeps its own idea of the KV state so
/// a wrong reuse promise is caught.
private final class SessionDriver: CoreMLDriving, Sendable {
    struct Call: Sendable, Equatable { var tokens: [Int]; var reused: Int }
    private struct State { var calls: [Call] = []; var state: [Int] = []; var replies: [String] }
    private let value: Mutex<State>
    let contextLength: Int
    let batchSize: Int
    var promptFamily: CoreMLPromptFamily { .qwen3 }
    init(contextLength: Int = 2_048, batchSize: Int = 1, replies: [String] = ["Reply one", "Reply two", "Reply three", "Reply four"]) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        value = Mutex(State(replies: replies))
    }
    var calls: [Call] { value.withLock { $0.calls } }

    static func scalars(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int] {
        Self.scalars(CoreMLPrompt.render(instructions: instructions, examples: examples, prompt: prompt, family: .qwen3))
    }
    func encode(_ text: String) async throws -> [Int] { Self.scalars(text) }
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration {
        try await generate(tokens: tokens, reusingPrefix: 0, outputLimit: outputLimit)
    }
    func generate(tokens: [Int], reusingPrefix: Int, outputLimit: Int) async throws -> CoreMLGeneration {
        try value.withLock { s in
            // A reuse promise must match what this "native state" really holds.
            if reusingPrefix > 0 {
                guard Array(s.state.prefix(reusingPrefix)) == Array(tokens.prefix(reusingPrefix)), s.state.count >= reusingPrefix else {
                    throw LLMError.failed("reuse promise does not match the state")
                }
            }
            s.calls.append(Call(tokens: tokens, reused: reusingPrefix))
            let reply = s.replies.isEmpty ? "More" : s.replies.removeFirst()
            let generated = Self.scalars(reply)
            s.state = tokens + generated
            return CoreMLGeneration(text: reply, stopReason: "eos_token", tokens: generated, prefilled: tokens.count - reusingPrefix)
        }
    }
}

struct CoreMLSessionTests {
    private let spec = CoreMLModels.specs[0]

    private func preparedBackend(_ driver: SessionDriver, outputLimit: Int = 64) async throws -> CoreMLBackend {
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/fixture"), outputTokenLimit: outputLimit) { _ in driver }
        try await backend.prepare()
        return backend
    }

    @Test func unpreparedBackendOffersNoSession() async {
        let backend = CoreMLBackend(spec: spec, folder: URL(filePath: "/absent")) { _ in SessionDriver() }
        await #expect(throws: LLMError.self) { _ = try await backend.makeSession() }
    }

    @Test func turnTwoPrefillsOnlyItsNewTokens() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean."))
        try await session.append(.text("first words"))
        #expect(try await session.respond(to: "Go.") == "Reply one")
        try await session.append(.text("second words"))
        #expect(try await session.respond(to: "Again.") == "Reply two")

        let calls = driver.calls
        #expect(calls.count == 2)
        #expect(calls[0].reused == 0)
        // Turn 2 continues exactly the tokens turn 1 left in the state: its prompt plus what it generated.
        let state = calls[0].tokens + SessionDriver.scalars("Reply one")
        #expect(calls[1].reused == state.count)
        #expect(Array(calls[1].tokens.prefix(state.count)) == state)
        let suffix = String(String.UnicodeScalarView(calls[1].tokens.dropFirst(state.count).compactMap(Unicode.Scalar.init)))
        #expect(suffix == CoreMLPrompt.continuation(user: "second words\n\nAgain.", family: .qwen3))
    }

    @Test func reusedPrefixIsAlignedSoNewTokensPrefillInFullBatches() async throws {
        let driver = SessionDriver(batchSize: 8)
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean the text carefully."))
        _ = try await session.respond(to: "First request with enough words.")
        _ = try await session.respond(to: "Second.")
        let calls = driver.calls
        let held = calls[0].tokens.count + SessionDriver.scalars("Reply one").count
        let reused = calls[1].reused
        // Starts no later than what the state holds, re-prefills at most one batch of held tokens, and leaves
        // a whole number of batches to prefill.
        #expect(reused > 0 && reused <= held && held - reused < 8)
        #expect((calls[1].tokens.count - reused) % 8 == 0)
    }

    @Test func aStatelessCallInBetweenResetsTheSessionState() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean."))
        _ = try await session.respond(to: "One.")
        _ = try await backend.respond(instructions: "Other", prompt: "stateless")
        _ = try await session.respond(to: "Two.")
        #expect(driver.calls.map(\.reused) == [0, 0, 0])
    }

    @Test func anotherSessionInBetweenResetsTheState() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let first = try await backend.makeSession(), second = try await backend.makeSession()
        try await first.append(.instructions("A"))
        try await second.append(.instructions("B"))
        _ = try await first.respond(to: "1")
        _ = try await second.respond(to: "1")
        _ = try await first.respond(to: "2")
        _ = try await first.respond(to: "3")
        let reused = driver.calls.map(\.reused)
        #expect(reused[0] == 0 && reused[1] == 0 && reused[2] == 0)
        #expect(reused[3] > 0)
    }

    @Test func trimResetsTheStateAndKeepsTheSuffixWithinBudget() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean."))
        for index in 1...3 {
            try await session.append(.text("chunk number \(index) with some words"))
            _ = try await session.respond(to: "Go.")
        }
        let before = try await session.usage()
        try await session.trim(keepingSuffix: before.history / 2)
        let after = try await session.usage()
        #expect(after.history <= before.history / 2)
        #expect(after.head == before.head)
        _ = try await session.respond(to: "After trim.")
        let last = try #require(driver.calls.last)
        #expect(last.reused == 0)
        // The rebuilt prompt starts at the kept turn, not at the dropped first one.
        let rendered = String(String.UnicodeScalarView(last.tokens.compactMap(Unicode.Scalar.init)))
        #expect(!rendered.contains("chunk number 1"))
        #expect(rendered.contains("chunk number 3"))
    }

    @Test func budgetLeavesRoomForTheReply() async throws {
        let backend = try await preparedBackend(SessionDriver(contextLength: 1_000), outputLimit: 100)
        let session = try await backend.makeSession()
        #expect(session.tokenBudget == 1_000 - 100 - 2)
    }

    @Test func aTurnBeyondTheContextIsRefusedWithoutGenerating() async throws {
        let driver = SessionDriver(contextLength: 200)
        let backend = try await preparedBackend(driver, outputLimit: 50)
        let session = try await backend.makeSession()
        try await session.append(.text(String(repeating: "x", count: 400)))
        await #expect(throws: LLMError.contextTooLong) { _ = try await session.respond(to: "Go.") }
        #expect(driver.calls.isEmpty)
    }

    @Test func structuredRepliesDecodeStrictlyAndInvalidOutputThrows() async throws {
        let driver = SessionDriver(replies: [#"[{"sentence": 1, "text": "Hello."}]"#, "Sure, here you go"])
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Edit."))
        let edits = try await session.respondStructured([SentenceEdit].self, to: "1: hello")
        #expect(edits == [SentenceEdit(sentence: 1, text: "Hello.")])
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([SentenceEdit].self, to: "2: x") }
        let prompt = String(String.UnicodeScalarView(driver.calls[0].tokens.compactMap(Unicode.Scalar.init)))
        #expect(prompt.contains("JSON Schema"))
    }

    @Test func unloadEndsOpenSessionsAndCloseEndsOne() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        _ = try await session.respond(to: "One.")
        await backend.unload()
        try await backend.prepare()
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "Two.") }
        let next = try await backend.makeSession()
        await next.close()
        await #expect(throws: LLMSessionError.closed) { _ = try await next.respond(to: "x") }
        #expect(driver.calls.count == 1)
    }

    @Test func sessionTurnsKeepTheSingleWorkerGuard() async throws {
        let backend = try await preparedBackend(SessionDriver())
        let session = try await backend.makeSession()
        // While another native operation owns the worker, a session turn is refused, not run alongside.
        try backend.cancellationForTesting.begin()
        await #expect(throws: LLMError.self) { _ = try await session.respond(to: "busy") }
        backend.cancellationForTesting.settle()
        #expect(try await session.respond(to: "free") == "Reply one")
    }

    @Test func qwenAndGemmaContinuationsCloseTheReplyAndOpenTheNextTurn() {
        #expect(CoreMLPrompt.continuation(user: "Hi", family: .qwen3)
            == "<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(CoreMLPrompt.continuation(user: " Hi ", family: .gemma3)
            == "<end_of_turn>\n<start_of_turn>user\nHi<end_of_turn>\n<start_of_turn>model\n")
    }
}

// MARK: - Real-model probe

private let probeEnvironment = ProcessInfo.processInfo.environment
private let probeEnabled = probeEnvironment["LEGATO_SESSION_PROBE"] == "1"
private let probeRoot: URL = probeEnvironment["LEGATO_TEST_MODEL_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? URL.applicationSupportDirectory.appending(path: "Legato/Models", directoryHint: .isDirectory)

/// Numbered sentences, long enough that a full prefill is clearly measurable.
func probeContext(sentences: Int) -> String {
    (1...sentences).map { "\($0): The harbour master logged boat number \($0) arriving with a cargo of timber and rope." }
        .joined(separator: "\n")
}

@Suite(.serialized) struct CoreMLSessionProbe {
    /// Turn 2 reuses the state: it prefills only its new tokens, and it answers exactly what a fresh state
    /// given the same token sequence answers (greedy).
    @Test(.enabled(if: probeEnabled, "set LEGATO_SESSION_PROBE=1 (real ANEMLL, installed Core ML model)"))
    func turnTwoReusesTheNativeState() async throws {
        let spec = try #require(CoreMLModels.spec(id: CoreMLModels.qwen3_1_7bID))
        let folder = spec.folder(root: probeRoot)
        let backend = CoreMLBackend(spec: spec, folder: folder, outputTokenLimit: 128)
        try await backend.prepare()
        let session = try #require(try await backend.makeSession() as? CoreMLSession)
        try await session.append(.instructions("You answer questions about the log in at most eight words."))
        try await session.append(.text(probeContext(sentences: 40)))
        let clock = ContinuousClock()
        var start = clock.now
        let reply1 = try await session.respond(to: "Which cargo did boat 3 bring?")
        let wall1 = clock.now - start
        let turn1 = try #require(await session.lastTurn)
        try await session.append(.text("41: The ferry to the island leaves at noon."))
        start = clock.now
        let reply2 = try await session.respond(to: "When does the ferry leave?")
        let wall2 = clock.now - start
        let turn2 = try #require(await session.lastTurn)

        let fresh = try #require(try await backend.makeSession() as? CoreMLSession)
        start = clock.now
        let replay = try await backend.sessionTurn(fresh.id, tokens: turn2.prompt)
        let wallFresh = clock.now - start
        print("""
            COREML-PROBE turn1: prompt \(turn1.promptTokens) prefilled \(turn1.prefilled) prefill \(turn1.prefillSeconds)s wall \(wall1) reply \(reply1.debugDescription)
            COREML-PROBE turn2: prompt \(turn2.promptTokens) prefilled \(turn2.prefilled) prefill \(turn2.prefillSeconds)s wall \(wall2) reply \(reply2.debugDescription)
            COREML-PROBE fresh: prompt \(turn2.promptTokens) prefilled \(replay.prefilled) prefill \(replay.prefillSeconds)s wall \(wallFresh) reply \(replay.text.debugDescription)
            """)
        #expect(turn2.prefilled < turn1.prefilled / 5)
        #expect(turn2.prefillSeconds < turn1.prefillSeconds / 3)
        #expect(replay.prefilled == turn2.promptTokens)
        #expect(replay.text == reply2)
        await session.close(); await fresh.close()
        await backend.unload()
    }
}
