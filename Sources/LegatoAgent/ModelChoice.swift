import Foundation
import LegatoRoom

/// The writing preferences shared by the composer's Magic button and spoken instructions.
public struct ComposerWritingSettings: Sendable {
    public static let modelKey = "composer.liveModel"
    public static let promptKey = "composer.personalPrompt"
    public let model: ModelChoice
    public let personalPrompt: String

    public init(in defaults: UserDefaults = .standard) {
        model = ModelChoice(rawValue: defaults.string(forKey: Self.modelKey) ?? "") ?? .haiku
        personalPrompt = defaults.string(forKey: Self.promptKey) ?? ""
    }
}

public enum ModelChoice: String, Codable, CaseIterable, Sendable {
    case haiku = "claude-haiku-5-5", sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5"
    public var thinking: JSONValue { .object(["type": .string(self == .haiku ? "disabled" : (self == .sonnet ? "between_tools" : "adaptive"))]) }
}
