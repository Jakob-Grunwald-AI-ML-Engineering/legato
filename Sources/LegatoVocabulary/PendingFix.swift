import Foundation

/// A cleanup fix (`raw` became `target`) seen in some runs but not yet often enough to be learned.
public struct PendingFix: Sendable, Equatable, Codable {
    public var raw: String
    public var target: String
    /// The distinct run ids that produced it.
    public var ids: [UUID]
    public var score: Double
    public var lastSeen: Date

    public init(raw: String, target: String, ids: [UUID] = [], score: Double = 1, lastSeen: Date) {
        self.raw = raw
        self.target = target
        self.ids = ids
        self.score = score
        self.lastSeen = lastSeen
    }

    /// The score decayed to `now`.
    public func effectiveScore(now: Date, halfLife: TimeInterval = Decay.defaultHalfLife) -> Double {
        Decay.effectiveScore(score, lastSeen: lastSeen, now: now, halfLife: halfLife)
    }
}
