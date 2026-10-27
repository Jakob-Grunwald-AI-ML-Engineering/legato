// CI-ONLY STUB of the `Tokenizers` module. Never shipped; used only when Package.swift runs with
// LEGATO_STUB_DEPS=1 so CI can compile and test the package without building swift-transformers.
// It declares ONLY the symbols Legato's own code and tests use, with matching signatures and no behaviour.
// When the real dependency is bumped, or Legato calls a new API from it, update this stub to match.

import Foundation

public enum TokenizerError: Error, Sendable { case missingChatTemplate }

public protocol Tokenizer: Sendable {
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String
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

public enum AutoTokenizer {
    public static func from(modelFolder: URL) async throws -> any Tokenizer {
        fatalError("stub: AutoTokenizer.from")
    }
}
