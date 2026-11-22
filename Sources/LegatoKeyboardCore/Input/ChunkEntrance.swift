import Foundation

/// How a chunk's insert enters the field (#300): as a very fast character-by-character burst ("typewriter pace, but really
/// fast"), still one chunk with one check. The caret hops to the chunk's place and the delete run go out at once; only the
/// insert is written piece by piece. Platform-neutral and pure: the iPhone queue (`FieldQueue`) and the Mac queue time
/// the pieces themselves.
///
/// The pace is one piece per 60 Hz frame on every platform (Jakob, 2026-11-18): the fastest that still visibly types in
/// hosts that redraw text at 60 Hz (pieces within one frame show as a block), and accuracy sets no lower bound (hosts
/// apply a whole burst in order, measured). A piece is one grapheme (an extended grapheme cluster: an emoji sequence, a
/// letter with combining marks and CRLF are never split) until the burst would run past `capMs`; beyond that graphemes
/// group into pieces, still one per frame, so the whole burst (the gaps between its pieces) never exceeds `capMs`.
/// Disabled (Reduce Motion, a flush, text a whole write must carry), the insert is one piece with no gap.
public enum ChunkEntrance {
    /// One 60 Hz frame.
    public static let gapMs = 1000.0 / 60
    /// No gap below a frame: faster pieces land in the same frame.
    public static let minGapMs = gapMs
    /// The key-wait budget is 500 ms; a key waits at most `capMs` behind a burst.
    public static let capMs = 250.0

    /// Staged iPhone delivery settings, estimated until measured on the phone.
    public static let typewriterGapMs = 8.0
    /// Leave room inside the 150 ms target for the queue timer and host writes.
    public static let typewriterCapMs = 112.0
    public static let typewriterCharacterLimit = 48

    public static func insertsStagedTextWhole(_ text: String) -> Bool {
        text.count > typewriterCharacterLimit
    }

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
        let pieces = group(graphemes, into: count)
        return Plan(pieces: pieces, gapMs: gap)
    }

    /// Fit staged text into a short burst by grouping graphemes. The cutoff uses the original text before the queue
    /// adds capitalization and spacing. Longer units and Reduce Motion use one write.
    public static func typewriterPlan(_ text: String, insertingWhole: Bool, enabled: Bool = true) -> Plan {
        plan(text, enabled: enabled && !insertingWhole, gapMs: typewriterGapMs,
             minGapMs: typewriterGapMs, capMs: typewriterCapMs)
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
