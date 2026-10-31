import Foundation
import LegatoRoom

public enum ModelChoice: String, Codable, CaseIterable, Sendable {
    case haiku = "claude-haiku-5-5", sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5"
    public var thinking: JSONValue { .object(["type": .string(self == .haiku ? "disabled" : (self == .sonnet ? "between_tools" : "adaptive"))]) }
}
public enum ComposerMode: String, Codable, CaseIterable, Sendable { case message, email, prompt, note, auto }
public struct AgentConfiguration: Sendable {
    public var liveModel: ModelChoice
    public var mode: ComposerMode
    public var personalPrompt: String
    public var hostActionContext: (@Sendable () async -> ComposerHostActionContext?)?
    public var performHostAction: (@Sendable (ComposerHostAction) async -> ComposerHostActionResult)?
    public var vocabulary: @Sendable (String) async -> [String]
    public init(liveModel: ModelChoice = .haiku,
                mode: ComposerMode = .message, personalPrompt: String = "",
                vocabulary: @escaping @Sendable (String) async -> [String] = { _ in [] },
                hostActionContext: (@Sendable () async -> ComposerHostActionContext?)? = nil,
                performHostAction: (@Sendable (ComposerHostAction) async -> ComposerHostActionResult)? = nil) {
        self.liveModel = liveModel; self.mode = mode
        self.personalPrompt = personalPrompt; self.vocabulary = vocabulary
        self.hostActionContext = hostActionContext; self.performHostAction = performHostAction
    }
}
