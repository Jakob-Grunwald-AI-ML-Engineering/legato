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

    // MARK: Review findings

    private static func text(_ tokens: [Int]) -> String {
        String(String.UnicodeScalarView(tokens.compactMap(Unicode.Scalar.init)))
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
        _ = try await session.respondStructured([SentenceEdit].self, to: "Edit.")
        try await session.append(.text("2: b"))
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([SentenceEdit].self, to: "Edit.") }
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
        let prompt2 = turn2.prompt
        let replay = try await backend.sessionTurn(fresh.id) { _ in prompt2 }.generation
        let wallFresh = clock.now - start

        // The continuation the session appended as raw text tokenizes exactly as the checkpoint's own chat
        // template renders a two-turn history from that point on (end marker, user turn, generation prompt).
        let instructions = "You answer questions about the log in at most eight words."
        let message1 = probeContext(sentences: 40) + "\n\nWhich cargo did boat 3 bring?"
        let message2 = "41: The ferry to the island leaves at noon.\n\nWhen does the ferry leave?"
        let driver = try #require(try await backend.sessionRuntime(session.id) as? NativeCoreMLDriver)
        let continuation = try await driver.encode(CoreMLPrompt.continuation(user: message2, family: .qwen3))
        let canonical = try driver.canonicalTokens(messages: [
            ["role": "system", "content": instructions], ["role": "user", "content": message1],
            ["role": "assistant", "content": reply1], ["role": "user", "content": message2],
        ])
        let continuationMatches = Array(prompt2.suffix(continuation.count)) == continuation
            && Array(canonical.suffix(continuation.count)) == continuation

        // Warm kickstart: a new run on a session whose head was prefilled ahead, against a cold session.
        let runText = "[run 2] " + probeContext(sentences: 2)
        let warm = try #require(try await backend.makeSession() as? CoreMLSession)
        try await warm.append(.instructions(instructions + " " + probeContext(sentences: 20)))
        try await warm.warm()
        let headWarm = try #require(await warm.lastWarm)
        try await warm.append(.text(runText))
        start = clock.now
        _ = try await warm.respond(to: "Which cargo did boat 2 bring?")
        let wallWarm = clock.now - start
        let warmTurn = try #require(await warm.lastTurn)
        let cold = try #require(try await backend.makeSession() as? CoreMLSession)
        try await cold.append(.instructions(instructions + " " + probeContext(sentences: 20)))
        try await cold.append(.text(runText))
        start = clock.now
        _ = try await cold.respond(to: "Which cargo did boat 2 bring?")
        let wallCold = clock.now - start
        let coldTurn = try #require(await cold.lastTurn)

        print("""
            COREML-PROBE turn1: prompt \(turn1.promptTokens) prefilled \(turn1.prefilled) prefill \(turn1.prefillSeconds)s wall \(wall1) reply \(reply1.debugDescription)
            COREML-PROBE turn2: prompt \(turn2.promptTokens) prefilled \(turn2.prefilled) prefill \(turn2.prefillSeconds)s wall \(wall2) reply \(reply2.debugDescription)
            COREML-PROBE fresh: prompt \(turn2.promptTokens) prefilled \(replay.prefilled) prefill \(replay.prefillSeconds)s wall \(wallFresh) reply \(replay.text.debugDescription)
            COREML-PROBE continuation tokens \(continuation.count) match canonical template: \(continuationMatches)
            COREML-PROBE kickstart warm: head prefilled \(headWarm.prefilled) ahead in \(headWarm.seconds)s; run prompt \(warmTurn.promptTokens) prefilled \(warmTurn.prefilled) prefill \(warmTurn.prefillSeconds)s wall \(wallWarm)
            COREML-PROBE kickstart cold: run prompt \(coldTurn.promptTokens) prefilled \(coldTurn.prefilled) prefill \(coldTurn.prefillSeconds)s wall \(wallCold)
            """)
        #expect(turn2.prefilled < turn1.prefilled / 5)
        #expect(turn2.prefillSeconds < turn1.prefillSeconds / 3)
        #expect(replay.prefilled == turn2.promptTokens)
        #expect(replay.text == reply2)
        #expect(continuationMatches)
        #expect(warmTurn.prefilled < coldTurn.prefilled)
        await warm.close(); await cold.close()
        await session.close(); await fresh.close()
        await backend.unload()
    }
}
