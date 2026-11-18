import Foundation

/// How a chunk's insert enters the field (#300): as a very fast character-by-character burst ("typewriter pace, but really
/// fast"), still one chunk with one check. The caret hops to the chunk's place and the delete run go out at once; only the
/// insert is written piece by piece. Platform-neutral and pure: the iPhone queue (`FieldQueue`) and the Mac queue time
/// the pieces themselves.
///
/// The pace is the display's: one piece per frame, the fastest that still visibly types (pieces written within one
/// frame show as a block, and accuracy sets no lower bound: hosts apply a whole burst in order, measured). A piece is one
/// grapheme (an extended grapheme cluster: an emoji sequence, a letter with combining marks and CRLF are never split)
/// until the burst would run past `capMs`; beyond that graphemes group into pieces, still one per frame, so the whole
/// burst (the gaps between its pieces) never exceeds `capMs`. Disabled (Reduce Motion, a flush, text a whole write must
/// carry), the insert is one piece with no gap.
public enum ChunkEntrance {
    /// One frame at 120 Hz, for callers that do not know their display.
    public static let gapMs = frameMs(fps: 120)
    /// No gap below a frame: faster pieces land in the same frame.
    public static let minGapMs = gapMs
    /// The key-wait budget is 500 ms; a key waits at most `capMs` behind a burst.
    public static let capMs = 250.0

    /// One frame of a display refreshing `fps` times a second (bounded to 30–240 Hz).
    public static func frameMs(fps: Int) -> Double { 1000 / Double(min(240, max(30, fps))) }

    public struct Plan: Sendable, Equatable {
        /// The insert's pieces in order; joined they are exactly the text.
        public var pieces: [String]
        /// The wait between two pieces (0 with one piece).
        public var gapMs: Double
        /// The burst's duration: the gaps between its pieces.
        public var durationMs: Double { Double(max(0, pieces.count - 1)) * gapMs }
    }

    /// `gapMs` is the display's frame (`frameMs(fps:)`); `minGapMs` defaults to it.
    public static func plan(_ text: String, enabled: Bool = true, gapMs: Double = gapMs, minGapMs: Double? = nil,
                            capMs: Double = capMs) -> Plan {
        let minGapMs = minGapMs ?? gapMs
        let graphemes = Array(text)
        guard enabled, graphemes.count > 1, gapMs > 0 else { return Plan(pieces: text.isEmpty ? [] : [text], gapMs: 0) }
        let n = graphemes.count
        // The gap that fits every grapheme in the cap, within [minGapMs, gapMs].
        let gap = min(gapMs, max(min(minGapMs, gapMs), capMs / Double(n - 1)))
        let count = min(n, max(2, Int(capMs / gap) + 1))
        let pieces = group(graphemes, into: count)
        return Plan(pieces: pieces, gapMs: gap)
    }

    /// `graphemes` in `count` even groups (the first `n % count` carry one more), in order, never inside a cluster.
    private static func group(_ graphemes: [Character], into count: Int) -> [String] {
        let n = graphemes.count
        var pieces: [String] = []
        pieces.reserveCapacity(count)
        var start = 0
        for index in 0..<count {
            let size = n / count + (index < n % count ? 1 : 0)
            pieces.append(String(graphemes[start..<(start + size)]))
            start += size
        }
        return pieces
    }

    /// The wall-clock guard of a burst whose writes cost time (the Mac's Accessibility writes take milliseconds each, an
    /// iPhone proxy's insert almost none): the burst never runs past `capMs` counted from its start. `elapsedMs` is the
    /// time since the burst began, `writeMs` what one write costs (the last one measured). When the pieces still to go no
    /// longer fit (each costs a gap and a write), they are written in fewer, fatter pieces rather than stretched, down to
    /// all of them in one. `waitMs` is the pause before the next piece: a gap, or none when no budget is left.
    public static func fit(_ remaining: [String], elapsedMs: Double, writeMs: Double, gapMs: Double,
                           capMs: Double = capMs) -> (pieces: [String], waitMs: Double) {
        guard remaining.count > 1 else { return (remaining, elapsedMs + gapMs + writeMs <= capMs ? gapMs : 0) }
        let cost = max(0.001, gapMs + writeMs)
        let affordable = max(1, Int(max(0, capMs - elapsedMs) / cost))
        let waitMs = elapsedMs + cost <= capMs ? gapMs : 0
        guard affordable < remaining.count else { return (remaining, waitMs) }
        return (group(Array(remaining.joined()), into: affordable), waitMs)
    }
}
