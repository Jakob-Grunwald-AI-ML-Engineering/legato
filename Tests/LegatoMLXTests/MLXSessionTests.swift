import Foundation
import LegatoCore
import MLXLMCommon
import Synchronization
import Testing
@testable import LegatoMLX

/// One fake `ChatSession`: replies in order and reports, like mlx-swift-lm, how many prompt tokens it
/// prefilled versus served from its cache (one token per word here).
private final class FakeChat: MLXChatTurning, @unchecked Sendable {
    let replies: Mutex<[String]>
    let messages = Mutex<[String]>([])
    let devices = Mutex<[ComputeDevice]>([])
    private let cached = Mutex(0)
    init(replies: [String], history: [Chat.Message], instructions: String) {
        self.replies = Mutex(replies)
        // A new chat starts with nothing cached; its first turn prefills the history too.
        _ = history; _ = instructions
    }
    func tokenCount(_ text: String) async -> Int { text.split(whereSeparator: \.isWhitespace).count }
    func stream(_ message: String, device: ComputeDevice) -> AsyncThrowingStream<MLXTurnEvent, any Error> {
        messages.withLock { $0.append(message) }
        devices.withLock { $0.append(device) }
        let reply = replies.withLock { $0.isEmpty ? "More" : $0.removeFirst() }
        let cachedBefore = cached.withLock { value -> Int in defer { value += 10 }; return value }
        return AsyncThrowingStream { continuation in
            continuation.yield(.chunk(reply))
            continuation.yield(.info(MLXTurnStats(prefilled: 10, cached: cachedBefore, prefillSeconds: 0.01)))
            continuation.finish()
        }
    }
}

private final class ChatFactory: MLXGenerating, @unchecked Sendable {
    struct Made: Sendable { var instructions: String; var history: [String] }
    let made = Mutex<[Made]>([])
    let chats = Mutex<[FakeChat]>([])
    let replies: [String]
    let loads = Mutex(0)
    init(replies: [String] = ["One.", "Two.", "Three.", "Four."]) { self.replies = replies }
    func load(spec: MLXModelSpec, folder: URL, device: ComputeDevice) async throws { loads.withLock { $0 += 1 } }
    func stream(spec: MLXModelSpec, folder: URL, instructions: String, examples: [LLMExample], prompt: String,
                device: ComputeDevice) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func makeChat(spec: MLXModelSpec, folder: URL, instructions: String, history: [Chat.Message]) async throws -> any MLXChatTurning {
        let contents = history.map(\.content)
        made.withLock { $0.append(Made(instructions: instructions, history: contents)) }
        let chat = FakeChat(replies: replies, history: history, instructions: instructions)
        chats.withLock { $0.append(chat) }
        return chat
    }
}

private let qwen = MLXModels.spec(id: MLXModels.qwen3_1_7bID)!

private func installedFolder() throws -> URL {
    let folder = qwen.folder(root: tempRoot())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["config.json", "tokenizer.json", "model.safetensors"] { try Data("x".utf8).write(to: folder.appending(path: name)) }
    return folder
}

struct MLXSessionTests {
    private func backend(_ factory: ChatFactory, gpu: Bool = true) throws -> MLXBackend {
        MLXBackend(spec: qwen, folder: try installedFolder(), device: .gpu, canUseGPU: { gpu }, generator: factory)
    }

    @Test func oneChatSessionServesEveryTurnSoItsCacheIsReused() async throws {
        let factory = ChatFactory()
        let session = try await backend(factory).makeSession()
        try await session.append(.instructions("Clean."))
        try await session.append(.example(LLMExample(user: "um hi", assistant: "Hi.")))
        try await session.append(.text("first"))
        #expect(try await session.respond(to: "Go.") == "One.")
        try await session.append(.text("second"))
        #expect(try await session.respond(to: "Go.") == "Two.")
        #expect(factory.made.withLock { $0.count } == 1)
        let made = try #require(factory.made.withLock { $0.first })
        #expect(made.instructions == "Clean.")
        #expect(made.history == ["um hi", "Hi."])
        #expect(factory.chats.withLock { $0[0].messages.withLock { $0 } } == ["first\n\nGo.", "second\n\nGo."])
        let stats = try #require(await (session as? MLXSession)?.lastTurn)
        #expect(stats.cached > 0)
    }

    @Test func trimStartsAFreshChatFromTheKeptHistory() async throws {
        let factory = ChatFactory()
        let session = try await backend(factory).makeSession()
        try await session.append(.instructions("Clean."))
        for index in 1...3 { _ = try await session.respond(to: "turn \(index) with a few words") }
        let before = try await session.usage()
        try await session.trim(keepingSuffix: before.history / 2)
        #expect(try await session.usage().history <= before.history / 2)
        _ = try await session.respond(to: "after")
        let made = factory.made.withLock { $0 }
        #expect(made.count == 2)
        let history = made[1].history
        #expect(!history.contains("turn 1 with a few words"))
        #expect(history.contains("turn 3 with a few words"))
        #expect(history.count % 2 == 0)
    }

    @Test func structuredRepliesDecodeStrictly() async throws {
        let factory = ChatFactory(replies: [#"[{"sentence": 3, "text": "Yes."}]"#, "I changed sentence 3."])
        let session = try await backend(factory).makeSession()
        #expect(try await session.respondStructured([SentenceEdit].self, to: "3: yes") == [SentenceEdit(sentence: 3, text: "Yes.")])
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([SentenceEdit].self, to: "again") }
        #expect(factory.chats.withLock { $0[0].messages.withLock { $0[0] } }.contains("JSON Schema"))
    }

    @Test func turnsRunOnTheCPUWhileTheGPUIsOffLimits() async throws {
        let factory = ChatFactory()
        let session = try await backend(factory, gpu: false).makeSession()
        _ = try await session.respond(to: "x")
        #expect(factory.chats.withLock { $0[0].devices.withLock { $0 } } == [.cpu])
    }

    @Test func releasingTheModelEndsTheSession() async throws {
        let factory = ChatFactory()
        let mlx = try backend(factory)
        let session = try await mlx.makeSession()
        _ = try await session.respond(to: "x")
        await mlx.releaseWarmResources()
        await #expect(throws: LLMSessionError.closed) { _ = try await session.respond(to: "y") }
    }

    @Test func countingAndTrimmingNeverLoadTheModel() async throws {
        let factory = ChatFactory()
        let session = try await backend(factory).makeSession()
        try await session.append(.instructions("Clean."))
        try await session.append(.text("some pending words to count"))
        _ = try await session.usage()
        try await session.trim(keepingSuffix: 1)
        #expect(factory.loads.withLock { $0 } == 0)
        #expect(factory.made.withLock { $0.isEmpty })
    }

    @Test func aFailedStructuredReplyLeavesNoTraceInTheTranscript() async throws {
        let factory = ChatFactory(replies: ["Not JSON at all", "Fine."])
        let session = try await backend(factory).makeSession()
        try await session.append(.text("1: hi"))
        await #expect(throws: LLMSessionError.self) { _ = try await session.respondStructured([SentenceEdit].self, to: "Edit.") }
        _ = try await session.respond(to: "Plain.")
        let made = factory.made.withLock { $0 }
        // The chat that saw the bad reply is replaced by one restored without it, and the turn's text is sent again.
        #expect(made.count == 2)
        #expect(!made[1].history.contains("Not JSON at all"))
        #expect(factory.chats.withLock { $0[1].messages.withLock { $0 } } == ["1: hi\n\nPlain."])
    }

    @Test func warmOpensTheChatOnTheHead() async throws {
        let factory = ChatFactory()
        let session = try await backend(factory).makeSession()
        try await session.append(.instructions("Clean."))
        try await session.warm()
        _ = try await session.respond(to: "Go.")
        let made = factory.made.withLock { $0 }
        #expect(made.count == 1 && made[0].instructions == "Clean." && made[0].history.isEmpty)
    }

    @Test func budgetIsTheEdgeWindowLessTheReply() async throws {
        let session = try await backend(ChatFactory()).makeSession()
        #expect(session.tokenBudget == MLXBackend.sessionWindow - MLXBackend.replyLimit)
    }
}

// MARK: - Real-model probe

private let probeEnvironment = ProcessInfo.processInfo.environment
private let probeEnabled = probeEnvironment["LEGATO_SESSION_PROBE"] == "1"
private let probeRoot: URL = probeEnvironment["LEGATO_TEST_MODEL_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? URL.applicationSupportDirectory.appending(path: "Legato/Models", directoryHint: .isDirectory)

/// Needs the real MLX and its Metal shaders (an Xcode build):
///   TEST_RUNNER_LEGATO_SESSION_PROBE=1 xcodebuild test -scheme LegatoKit-Package -destination 'platform=macOS' \
///     -only-testing:LegatoMLXTests/MLXSessionProbe
@Suite(.serialized) struct MLXSessionProbe {
    @Test(.enabled(if: probeEnabled, "set LEGATO_SESSION_PROBE=1 (real MLX, installed MLX model)"))
    func turnTwoReusesTheKVCache() async throws {
        let folder = qwen.folder(root: probeRoot)
        let backend = MLXBackend(spec: qwen, folder: folder, device: .gpu, canUseGPU: { true })
        let session = try #require(try await backend.makeSession() as? MLXSession)
        let instructions = "You answer questions about the log in at most eight words."
        let context = (1...40).map { "\($0): The harbour master logged boat number \($0) arriving with a cargo of timber and rope." }
            .joined(separator: "\n")
        try await session.append(.instructions(instructions))
        try await session.append(.text(context))
        let clock = ContinuousClock()
        var start = clock.now
        let message1 = context + "\n\nWhich cargo did boat 3 bring?"
        let reply1 = try await session.respond(to: "Which cargo did boat 3 bring?")
        let wall1 = clock.now - start
        let turn1 = try #require(await session.lastTurn)
        try await session.append(.text("41: The ferry to the island leaves at noon."))
        let message2 = "41: The ferry to the island leaves at noon.\n\nWhen does the ferry leave?"
        start = clock.now
        let reply2 = try await session.respond(to: "When does the ferry leave?")
        let wall2 = clock.now - start
        let turn2 = try #require(await session.lastTurn)

        // A fresh chat restored from the same transcript, answering the same turn 2.
        let fresh = try await MLXChatGenerator().makeChat(spec: qwen, folder: folder, instructions: instructions,
                                                          history: [.user(message1), .assistant(reply1)])
        start = clock.now
        var replay = ""
        var freshStats: MLXTurnStats?
        for try await event in fresh.stream(message2, device: .gpu) {
            switch event { case .chunk(let text): replay += text; case .info(let stats): freshStats = stats }
        }
        let wallFresh = clock.now - start
        let freshTurn = try #require(freshStats)
        print("""
            MLX-PROBE turn1: prefilled \(turn1.prefilled) cached \(turn1.cached) prefill \(turn1.prefillSeconds)s wall \(wall1) reply \(reply1.debugDescription)
            MLX-PROBE turn2: prefilled \(turn2.prefilled) cached \(turn2.cached) prefill \(turn2.prefillSeconds)s wall \(wall2) reply \(reply2.debugDescription)
            MLX-PROBE fresh: prefilled \(freshTurn.prefilled) cached \(freshTurn.cached) prefill \(freshTurn.prefillSeconds)s wall \(wallFresh) reply \(replay.debugDescription)
            """)
        #expect(turn2.cached > 0)
        #expect(turn2.prefilled < turn1.prefilled / 5)
        #expect(replay == reply2)
        await session.close()
        await backend.releaseWarmResources()
    }
}
