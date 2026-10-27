import Foundation

/// Time decay of a vocabulary score.
///
/// A term's stored `score` is never rewritten as time passes; its weight is computed when it is needed from
/// `lastSeen`: `score × 0.5^(age / halfLife)`. Eviction of pending candidates and the hint ranking both use it.
public enum Decay {
    /// The default half-life: thirty days.
    public static let defaultHalfLife: TimeInterval = 30 * 24 * 60 * 60

    /// `score` halved once per `halfLife` elapsed between `lastSeen` and `now`. A `lastSeen` in the future counts as age zero.
    public static func effectiveScore(
        _ score: Double, lastSeen: Date, now: Date, halfLife: TimeInterval = defaultHalfLife
    ) -> Double {
        let age = max(0, now.timeIntervalSince(lastSeen))
        guard halfLife > 0 else { return age == 0 ? score : 0 }
        return score * pow(0.5, age / halfLife)
    }
}
