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
    struct Made { var instructions: String; var history: [Chat.Message] }
    let made = Mutex<[Made]>([])
    let chats = Mutex<[FakeChat]>([])
    let replies: [String]
    init(replies: [String] = ["One.", "Two.", "Three.", "Four."]) { self.replies = replies }
    func load(spec: MLXModelSpec, folder: URL, device: ComputeDevice) async throws {}
    func stream(spec: MLXModelSpec, folder: URL, instructions: String, examples: [LLMExample], prompt: String,
                device: ComputeDevice) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func makeChat(spec: MLXModelSpec, folder: URL, instructions: String, history: [Chat.Message]) async throws -> any MLXChatTurning {
        made.withLock { $0.append(Made(instructions: instructions, history: history)) }
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
        #expect(made.history.map(\.content) == ["um hi", "Hi."])
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
        let history = made[1].history.map(\.content)
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

    @Test func budgetIsTheEdgeWindowLessTheReply() async throws {
        let session = try await backend(ChatFactory()).makeSession()
        #expect(session.tokenBudget == MLXBackend.sessionWindow - MLXBackend.replyLimit)
    }
}
