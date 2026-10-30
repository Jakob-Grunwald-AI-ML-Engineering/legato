import Foundation

public struct SonioxToken: Codable, Sendable, Equatable {
    public var text: String
    public var confidence: Double?
    public var isFinal: Bool
    public var startMs: Double?
    public var endMs: Double?
    public var language: String?
    enum CodingKeys: String, CodingKey {
        case text, confidence, language
        case isFinal = "is_final", startMs = "start_ms", endMs = "end_ms"
    }
    public init(text: String, confidence: Double? = nil, isFinal: Bool, startMs: Double? = nil, endMs: Double? = nil, language: String? = nil) {
        self.text = text; self.confidence = confidence; self.isFinal = isFinal
        self.startMs = startMs; self.endMs = endMs; self.language = language
    }
}
