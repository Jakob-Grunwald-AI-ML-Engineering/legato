/// The proposal under a finger at touch-down. A later row or field cannot inherit that tap.
public struct SuggestionTap: Sendable, Equatable {
    public let rank: Int
    public let word: String
    public let revision: Int
    public let documentID: String?
    public let before: String
    public let after: String

    public init(rank: Int, word: String, revision: Int, documentID: String?, before: String, after: String) {
        self.rank = rank
        self.word = word
        self.revision = revision
        self.documentID = documentID
        self.before = before
        self.after = after
    }

    public func matches(revision: Int, words: [String], documentID: String?, before: String, after: String) -> Bool {
        self.revision == revision && self.documentID == documentID && self.before == before && self.after == after
            && words.indices.contains(rank) && words[rank] == word
    }
}

/// A slot's frozen touch identity and its separate accessibility activation.
public struct SuggestionPress: Sendable {
    private var touch: SuggestionTap?

    public init() {}

    public mutating func began(_ tap: SuggestionTap?) { touch = tap }

    public mutating func activate(current: SuggestionTap?, accessibility: Bool = false) -> SuggestionTap? {
        defer { touch = nil }
        return accessibility ? current : touch
    }
}
