// CI-ONLY STUB of the `MLXLMCommon` module. Never shipped; used only when Package.swift runs with
// LEGATO_STUB_DEPS=1 so CI can compile and test the package without building mlx-swift-lm.
// It declares ONLY the symbols Legato's own code and tests use, with matching signatures and no behaviour.
// When the real dependency is bumped, or Legato calls a new API from it, update this stub to match.

import Foundation

public final class ModelContainer: Sendable {
    public var tokenizer: any Tokenizer { get async { fatalError("stub: ModelContainer.tokenizer") } }
}

public struct ModelConfiguration: Sendable {
    public init(directory: URL, extraEOSTokens: Set<String> = []) {}
}

public struct GenerateParameters: Sendable {
    public init(maxTokens: Int? = nil, temperature: Float = 0.6) {}
}

public enum Chat {
    public struct Message: Sendable {
        public enum Role: String, Sendable, Equatable { case user, assistant, system }
        public var role: Role
        public var content: String
        public static func user(_ content: String) -> Message { Message(role: .user, content: content) }
        public static func assistant(_ content: String) -> Message { Message(role: .assistant, content: content) }
    }
}

public struct GenerateCompletionInfo: Sendable {
    public let promptTokenCount: Int
    public var cachedPromptTokenCount: Int
    public let promptTime: TimeInterval
}

public enum Generation: Sendable {
    case chunk(String)
    case info(GenerateCompletionInfo)
}

public final class ChatSession: @unchecked Sendable {
    public init(
        _ model: ModelContainer, instructions: String? = nil, generateParameters: GenerateParameters = .init(),
        additionalContext: [String: any Sendable]? = nil
    ) {}
    public init(
        _ model: ModelContainer, instructions: String? = nil, history: [Chat.Message],
        generateParameters: GenerateParameters = .init(), additionalContext: [String: any Sendable]? = nil
    ) {}
    public func streamResponse(to messages: [Chat.Message]) -> AsyncThrowingStream<String, any Error> {
        fatalError("stub: ChatSession.streamResponse")
    }
    public func streamDetails(to messages: [Chat.Message]) -> AsyncThrowingStream<Generation, any Error> {
        fatalError("stub: ChatSession.streamDetails")
    }
}

public protocol Downloader: Sendable {
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}

public enum TokenizerError: Error, Sendable { case missingChatTemplate }

public protocol Tokenizer: Sendable {
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String
    func convertTokenToId(_ token: String) -> Int?
    func convertIdToToken(_ id: Int) -> String?
    var bosToken: String? { get }
    var eosToken: String? { get }
    var unknownToken: String? { get }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int]
}

public protocol TokenizerLoader: Sendable {
    func load(from directory: URL) async throws -> any Tokenizer
}
