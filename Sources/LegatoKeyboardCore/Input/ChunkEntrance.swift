import Foundation

/// How a chunk's insert enters the field (#300): as a very fast character-by-character burst ("typewriter pace, but really
/// fast"), still one chunk with one check. The caret hops to the chunk's place and the delete run go out at once; only the
/// insert is written piece by piece. Platform-neutral and pure: the iPhone queue (`FieldQueue`) and the Mac queue time
/// the pieces themselves.
///
/// A piece is one grapheme (an extended grapheme cluster: an emoji sequence, a letter with combining marks and CRLF are
/// never split) until the burst would run past `capMs`; then the gap between pieces shrinks, down to `minGapMs`, and
/// beyond that graphemes group into pieces, so the whole burst (the gaps between its pieces) never exceeds `capMs`.
/// Disabled (Reduce Motion, a flush, text a whole write must carry), the insert is one piece with no gap.
public enum ChunkEntrance {
    /// Estimates to be tuned on the phone and the Mac; the key-wait budget is 500 ms, so a key waits at most `capMs`.
    public static let gapMs = 8.0
    public static let minGapMs = 4.0
    public static let capMs = 250.0

    public struct Plan: Sendable, Equatable {
        /// The insert's pieces in order; joined they are exactly the text.
        public var pieces: [String]
        /// The wait between two pieces (0 with one piece).
        public var gapMs: Double
        /// The burst's duration: the gaps between its pieces.
        public var durationMs: Double { Double(max(0, pieces.count - 1)) * gapMs }
    }

    public static func plan(_ text: String, enabled: Bool = true, gapMs: Double = gapMs, minGapMs: Double = minGapMs,
                            capMs: Double = capMs) -> Plan {
        let graphemes = Array(text)
        guard enabled, graphemes.count > 1, gapMs > 0 else { return Plan(pieces: text.isEmpty ? [] : [text], gapMs: 0) }
        let n = graphemes.count
        // The gap that fits every grapheme in the cap, within [minGapMs, gapMs].
        let gap = min(gapMs, max(min(minGapMs, gapMs), capMs / Double(n - 1)))
        let count = min(n, max(2, Int(capMs / gap) + 1))
        // Even groups: the first `n % count` pieces carry one grapheme more.
        var pieces: [String] = []
        pieces.reserveCapacity(count)
        var start = 0
        for index in 0..<count {
            let size = n / count + (index < n % count ? 1 : 0)
            pieces.append(String(graphemes[start..<(start + size)]))
            start += size
        }
        return Plan(pieces: pieces, gapMs: gap)
    }
}
