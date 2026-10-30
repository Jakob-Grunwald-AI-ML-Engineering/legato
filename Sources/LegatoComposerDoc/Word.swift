import Foundation

public struct Word: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var confidence: Double?
    public var language: String?
    public var alternatives: [String]?
    public var pinned: Bool

    public init(id: String = UUID().uuidString, text: String, confidence: Double? = nil, language: String? = nil, alternatives: [String]? = nil, pinned: Bool = false) {
        self.id = id; self.text = text; self.confidence = confidence; self.language = language
        self.alternatives = alternatives; self.pinned = pinned
    }
}
