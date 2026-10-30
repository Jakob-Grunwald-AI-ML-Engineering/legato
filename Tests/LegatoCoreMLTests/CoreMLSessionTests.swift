import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoCoreML

/// Parks one generation inside the driver: `entered()` returns once it is there, `release()` lets it go on.
private final class GenerationHold: Sendable {
    private let enteredStream: AsyncStream<Void>, enteredContinuation: AsyncStream<Void>.Continuation
    private let proceedStream: AsyncStream<Void>, proceedContinuation: AsyncStream<Void>.Continuation
    init() {
        (enteredStream, enteredContinuation) = AsyncStream<Void>.makeStream()
        (proceedStream, proceedContinuation) = AsyncStream<Void>.makeStream()
    }
    func wait() async {
        enteredContinuation.yield(); enteredContinuation.finish()
        for await _ in proceedStream { break }
    }
    func entered() async { for await _ in enteredStream { break } }
    func release() { proceedContinuation.yield(); proceedContinuation.finish() }
}

/// A tokenizer-free driver: one token per Unicode scalar, so prefixes are easy to reason about. It records
/// every generation's tokens and the prefix it was told to reuse, and keeps its own idea of the KV state so
/// a wrong reuse promise is caught. Like the native driver, `tokens` checks the backend's cancellation.
private final class SessionDriver: CoreMLDriving, Sendable {
    struct Call: Sendable, Equatable { var tokens: [Int]; var reused: Int; var prefillOnly = false }
    enum Script: Sendable { case reply(String), cancel }
    private struct State {
        var calls: [Call] = []; var state: [Int] = []; var replies: [String]; var script: [Script] = []
        var cancellation: CoreMLCancellation?
        var hold: GenerationHold?
    }
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
    func attach(_ cancellation: CoreMLCancellation) -> Self { value.withLock { $0.cancellation = cancellation }; return self }
    /// The next generations follow `script` before the plain replies.
    func script(_ steps: [Script]) { value.withLock { $0.script = steps } }
    /// The next generation waits inside the driver until the hold is released.
    func holdNext() -> GenerationHold { let hold = GenerationHold(); value.withLock { $0.hold = hold }; return hold }

    static func scalars(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }
    func tokens(instructions: String, examples: [LLMExample], prompt: String) async throws -> [Int] {
        try value.withLock { $0.cancellation }?.check()
        return Self.scalars(CoreMLPrompt.render(instructions: instructions, examples: examples, prompt: prompt, family: .qwen3))
    }
    func encode(_ text: String) async throws -> [Int] { Self.scalars(text) }
    func generate(tokens: [Int], outputLimit: Int) async throws -> CoreMLGeneration {
        try await generate(tokens: tokens, reusingPrefix: 0, outputLimit: outputLimit)
    }
    private func checkPromise(_ s: State, _ tokens: [Int], _ reusingPrefix: Int) throws {
        // A reuse promise must match what this "native state" really holds.
        if reusingPrefix > 0 {
            guard s.state.count >= reusingPrefix, Array(s.state.prefix(reusingPrefix)) == Array(tokens.prefix(reusingPrefix)) else {
                throw LLMError.failed("reuse promise does not match the state")
            }
        }
    }
    func prefill(tokens: [Int], reusingPrefix: Int) async throws -> CoreMLPrefill {
        try value.withLock { s in
            try checkPromise(s, tokens, reusingPrefix)
            s.calls.append(Call(tokens: tokens, reused: reusingPrefix, prefillOnly: true))
            s.state = tokens
            return CoreMLPrefill(prefilled: tokens.count - reusingPrefix, seconds: 0)
        }
    }
    func generate(tokens: [Int], reusingPrefix: Int, outputLimit: Int) async throws -> CoreMLGeneration {
        if let hold = value.withLock({ s in defer { s.hold = nil }; return s.hold }) { await hold.wait() }
        return try value.withLock { s in
            try checkPromise(s, tokens, reusingPrefix)
            s.calls.append(Call(tokens: tokens, reused: reusingPrefix))
            let step: Script = s.script.isEmpty ? .reply(s.replies.isEmpty ? "More" : s.replies.removeFirst()) : s.script.removeFirst()
            switch step {
            case .cancel:
                // As the native driver on a window shift or a timeout: the state is touched, then cancelled.
                s.state = tokens
                s.cancellation?.cancel()
                throw CancellationError()
            case .reply(let reply):
                let generated = Self.scalars(reply)
                s.state = tokens + generated
                return CoreMLGeneration(text: reply, stopReason: "eos_token", tokens: generated, prefilled: tokens.count - reusingPrefix)
            }
        }
    }
}

private struct TestReply: LLMStructuredOutput, Codable, Hashable {
    var sentence: Int
    var text: String
    static var llmSchema: LLMSchema {
        .object(name: "TestReply", properties: [LLMSchemaProperty("sentence", .integer()), LLMSchemaProperty("text", .string())])
    }
}

struct CoreMLSessionTests {
    private let spec = CoreMLModels.specs[0]

    private func preparedBackend(_ driver: SessionDriver, outputLimit: Int = 64, spec: CoreMLModelSpec? = nil) async throws -> CoreMLBackend {
        let backend = CoreMLBackend(spec: spec ?? self.spec, folder: URL(filePath: "/fixture"), outputTokenLimit: outputLimit) { driver.attach($0) }
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

    @Test func trimKeepsTheSharedPrefixAndTheSuffixWithinBudget() async throws {
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
        // Requirement change (rolling session, Jakob): a trim keeps the state's prefix the rebuilt prompt still
        // shares (at least the head) instead of resetting it; the driver rejects any reuse its state lacks.
        let head = SessionDriver.scalars(CoreMLPrompt.head(instructions: "Clean.", examples: [], family: .qwen3))
        #expect(last.reused >= head.count)
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
        let edits = try await session.respondStructured([TestReply].self, to: "1: hello")
        #expect(edits == [TestReply(sentence: 1, text: "Hello.")])
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([TestReply].self, to: "2: x") }
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

    // MARK: Review findings

    private static func text(_ tokens: [Int]) -> String {
        String(String.UnicodeScalarView(tokens.compactMap(Unicode.Scalar.init)))
    }

    @Test func closeDuringGenerationRejectsTheLateReply() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        let hold = driver.holdNext()
        let turn = Task { try await session.respond(to: "In flight.") }
        await hold.entered()
        await session.close()
        hold.release()
        await #expect(throws: LLMSessionError.closed) { _ = try await turn.value }
    }

    @Test func aCancelledTurnLeavesTheSessionUsable() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean."))
        driver.script([.cancel])
        await #expect(throws: CancellationError.self) { _ = try await session.respond(to: "Timed out.") }
        // The cancellation belonged to that turn only.
        #expect(try await session.respond(to: "Next.") == "Reply one")
        _ = try await session.usage()
        try await session.trim(keepingSuffix: 0)
        #expect(try await session.respond(to: "After trim.") == "Reply two")
    }

    @Test func textAppendedDuringATurnGoesWithTheNextTurn() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.text("before"))
        let hold = driver.holdNext()
        let turn = Task { try await session.respond(to: "One.") }
        await hold.entered()
        try await session.append(.text("streamed in mid-turn"))
        hold.release()
        _ = try await turn.value
        _ = try await session.respond(to: "Two.")
        let last = Self.text(try #require(driver.calls.last).tokens)
        #expect(last.hasSuffix(CoreMLPrompt.continuation(user: "streamed in mid-turn\n\nTwo.", family: .qwen3)))
    }

    @Test func aTrimRequestedDuringATurnIsNotUndoneByIt() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean."))
        let hold = driver.holdNext()
        let turn = Task { try await session.respond(to: "first words") }
        await hold.entered()
        let trim = Task { try await session.trim(keepingSuffix: 0) }
        hold.release()
        _ = try await turn.value
        try await trim.value
        #expect(try await session.usage().history == 0)
        _ = try await session.respond(to: "after")
        #expect(!Self.text(try #require(driver.calls.last).tokens).contains("first words"))
    }

    @Test func anEmptyReplyAfterTheStateMovedReusesOnlyWhatStillMatches() async throws {
        let driver = SessionDriver(replies: ["Reply one", "   ", "Reply three"])
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean."))
        _ = try await session.respond(to: "One.")
        await #expect(throws: LLMError.emptyResponse) { _ = try await session.respond(to: "Two.") }
        // The native state now holds the empty reply, which the transcript never recorded: the next turn
        // reuses only the common prefix (the driver rejects any promise its state does not keep).
        #expect(try await session.respond(to: "Three.") == "Reply three")
        let calls = driver.calls
        let common = zip(calls[1].tokens + SessionDriver.scalars("   "), calls[2].tokens).prefix { $0 == $1 }.count
        #expect(calls[2].reused > 0 && calls[2].reused <= common)
        #expect(!Self.text(calls[2].tokens).contains("Two."))
    }

    @Test func aFailedStructuredReplyLeavesNoTraceInTheTranscript() async throws {
        let driver = SessionDriver(replies: [#"[{"sentence": 1, "text": "A."}]"#, "Sure, here you go", "Reply three"])
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.text("1: a"))
        _ = try await session.respondStructured([TestReply].self, to: "Edit.")
        try await session.append(.text("2: b"))
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([TestReply].self, to: "Edit.") }
        _ = try await session.respond(to: "Plain.")
        let last = Self.text(try #require(driver.calls.last).tokens)
        #expect(!last.contains("Sure, here you go"))
        // The failed turn's text is sent again with the next turn.
        #expect(last.hasSuffix(CoreMLPrompt.continuation(user: "2: b\n\nPlain.", family: .qwen3)))
    }

    @Test func warmPrefillsTheHeadSoTheFirstTurnPrefillsOnlyWhatFollows() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean the dictated text carefully."))
        try await session.append(.example(LLMExample(user: "um hi", assistant: "Hi.")))
        try await session.warm()
        let head = try #require(driver.calls.first)
        #expect(head.prefillOnly && head.reused == 0)
        try await session.append(.text("run one words"))
        _ = try await session.respond(to: "Go.")
        let turn = driver.calls[1]
        #expect(turn.reused == head.tokens.count)
        #expect(Array(turn.tokens.prefix(head.tokens.count)) == head.tokens)
    }

    @Test func aBudgetTrimKeepsTheHeadPrefilled() async throws {
        let driver = SessionDriver()
        let backend = try await preparedBackend(driver)
        let session = try await backend.makeSession()
        try await session.append(.instructions("Clean the dictated text carefully."))
        try await session.warm()
        let head = driver.calls[0].tokens.count
        for index in 1...3 { try await session.append(.text("run \(index) text")); _ = try await session.respond(to: "Go.") }
        try await session.trim(keepingSuffix: (try await session.usage().history) / 2)
        _ = try await session.respond(to: "After trim.")
        // The history after the head changed, the head did not: its state is reused.
        #expect(try #require(driver.calls.last).reused >= head)
    }

    // MARK: Prefix reuse on unprobed specs

    @Test func theProbedSpecAlignsReuseToFullBatchesOfNewTokens() {
        let policy = CoreMLReusePolicy(spec: CoreMLModels.spec(id: CoreMLModels.qwen3_1_7bID)!)
        let start = CoreMLReusePolicy.start(held: Array(0..<300), next: Array(0..<300) + Array(1_000..<1_040), batch: 64, policy: policy)
        #expect(start <= 300 && 300 - start < 64 && (340 - start) % 64 == 0)
    }

    @Test func anUnprobedStaticSliceSpecReusesOnlyOnUpstreamsBatchGrid() {
        let policy = CoreMLReusePolicy(spec: CoreMLModels.spec(id: CoreMLModels.qwen3_0_6bID)!)
        let start = CoreMLReusePolicy.start(held: Array(0..<300), next: Array(0..<300) + Array(1_000..<1_040), batch: 64, policy: policy)
        #expect(start == 256)
    }

    @Test(arguments: [
        (held: 300, total: 400, expectReuse: true),    // below the window throughout
        (held: 300, total: 600, expectReuse: false),   // this turn's prefill crosses the window
        (held: 600, total: 700, expectReuse: false),   // the held state already rotated
    ])
    func aSlidingWindowSpecNeverReusesAcrossTheWindow(held: Int, total: Int, expectReuse: Bool) {
        let policy = CoreMLReusePolicy(spec: CoreMLModels.spec(id: CoreMLModels.gemma3_1bID)!)
        let next = Array(0..<held) + Array(10_000..<(10_000 + total - held))
        let start = CoreMLReusePolicy.start(held: Array(0..<held), next: next, batch: 64, policy: policy)
        if expectReuse { #expect(start > 0 && start % 64 == 0 && start <= held) } else { #expect(start == 0) }
    }

    @Test func aSlidingWindowSessionFallsBackToAFullPrefillPastTheWindow() async throws {
        let driver = SessionDriver(contextLength: 4_096, batchSize: 64, replies: ["Short reply", "Second reply"])
        let backend = try await preparedBackend(driver, outputLimit: 64, spec: CoreMLModels.spec(id: CoreMLModels.gemma3_1bID)!)
        let session = try await backend.makeSession()
        try await session.append(.text(String(repeating: "word ", count: 120)))  // ~600 tokens: past the 512 window
        _ = try await session.respond(to: "One.")
        _ = try await session.respond(to: "Two.")
        #expect(driver.calls.map(\.reused) == [0, 0])
    }

    @Test func qwenAndGemmaContinuationsCloseTheReplyAndOpenTheNextTurn() {
        #expect(CoreMLPrompt.continuation(user: "Hi", family: .qwen3)
            == "<|im_end|>\n<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(CoreMLPrompt.continuation(user: " Hi ", family: .gemma3)
            == "<end_of_turn>\n<start_of_turn>user\nHi<end_of_turn>\n<start_of_turn>model\n")
    }
}

