import Foundation
import LegatoRoom

public enum ModelChoice: String, Codable, CaseIterable, Sendable {
    case haiku = "claude-haiku-5-5", sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5"
    public var thinking: JSONValue { .object(["type": .string(self == .haiku ? "disabled" : (self == .sonnet ? "between_tools" : "adaptive"))]) }
}
