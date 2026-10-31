import Foundation
import LegatoComposerDoc

/// Raw speech held outside the document until the independent sentence stage validates it.
public struct DictationSentence: Sendable {
    public let id: String
    public let sequence: Int
    public let sourceSegmentID: String
    public let sourceSegmentIDs: [String]
    public let words: [Word]
    public let origin: Double
    public let continuation: Bool
    public init(id: String = UUID().uuidString, sequence: Int, sourceSegmentID: String, words: [Word], origin: Double, sourceSegmentIDs: [String]? = nil, continuation: Bool = false) {
        self.id = id; self.sequence = sequence; self.sourceSegmentID = sourceSegmentID; self.sourceSegmentIDs = sourceSegmentIDs ?? [sourceSegmentID]; self.words = words; self.origin = origin; self.continuation = continuation
    }
    public var text: String { words.map(\.text).joined(separator: " ") }
}
public struct ValidatedDictation: Sendable {
    public let sentenceID: String
    public let sequence: Int
    public let words: [Word]
    public let sourceWordIDs: [String]
    public let continuation: Bool
    public init(sentenceID: String, sequence: Int, words: [Word], sourceWordIDs: [String], continuation: Bool = false) {
        self.sentenceID = sentenceID; self.sequence = sequence; self.words = words; self.sourceWordIDs = sourceWordIDs; self.continuation = continuation
    }
}
