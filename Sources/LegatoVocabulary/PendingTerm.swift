import Foundation

/// A word or phrase seen in dictation that has not yet earned a place in the vocabulary.
public struct PendingTerm: Sendable, Equatable, Codable {
    public var text: String
    /// What the learner thinks the term is.
    public var kind: VocabularyEntry.Kind
    /// The distinct dictation ids that contained it.
    public var ids: [UUID]
    public var score: Double
    public var lastSeen: Date

    public init(text: String, kind: VocabularyEntry.Kind = .term, ids: [UUID] = [], score: Double = 1, lastSeen: Date) {
        self.text = text
        self.kind = kind
        self.ids = ids
        self.score = score
        self.lastSeen = lastSeen
    }

    /// The score decayed to `now`.
    public func effectiveScore(now: Date, halfLife: TimeInterval = Decay.defaultHalfLife) -> Double {
        Decay.effectiveScore(score, lastSeen: lastSeen, now: now, halfLife: halfLife)
    }
}
