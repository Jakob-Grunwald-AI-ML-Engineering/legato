import Foundation

public struct SonioxToken: Codable, Sendable, Equatable {
    public var text: String
    public var confidence: Double?
    public var isFinal: Bool
    public var startMs: Double?
    public var endMs: Double?
    public var language: String?
    /// The diarized speaker ("1", "2", …); only present when the stream asked for diarization.
    public var speaker: String?
    enum CodingKeys: String, CodingKey {
        case text, confidence, language, speaker
        case isFinal = "is_final", startMs = "start_ms", endMs = "end_ms"
    }
    public init(text: String, confidence: Double? = nil, isFinal: Bool, startMs: Double? = nil, endMs: Double? = nil, language: String? = nil, speaker: String? = nil) {
        self.text = text; self.confidence = confidence; self.isFinal = isFinal
        self.startMs = startMs; self.endMs = endMs; self.language = language; self.speaker = speaker
    }
}
