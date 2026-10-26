import Foundation

/// The pure math of the typewriter reveal: how many characters of a growing text are shown after a frame.
/// Each frame reveals the share of the pending text that fits `windowMs`, so the gap closes exponentially
/// and the reveal never lags far behind however much text arrives at once.
public enum TypewriterDrain {
    /// Time constant of the drain: a frame reveals a slice sized to empty the pending text over about this long.
    public static let windowMs = 250.0

    /// Characters revealed after a frame of `dtMs`: at least one more, never past `target`.
    public static func step(revealed: Int, target: Int, dtMs: Double) -> Int {
        guard revealed < target else { return target }
        let pending = Double(target - revealed)
        let slice = max(1, Int((pending * dtMs / windowMs).rounded(.up)))
        return min(target, revealed + slice)
    }

    /// Whether `next` only grows `prev` (a streaming append). Only that animates; a rewrite shows at once.
    public static func isPrefixGrowth(prev: String, next: String) -> Bool {
        next.hasPrefix(prev)
    }
}
