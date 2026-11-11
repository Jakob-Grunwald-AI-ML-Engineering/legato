import Foundation

/// Plans how a change of known text goes into the field, and at what pace. Pure.
///
/// - Spans: the minimal grapheme diff (`ShadowEditPlanner.diff`); a word whose graphemes change by at least half is
///   replaced whole ("Thursday" → "Friday"; "colour" → "color" stays one deleted letter); changes a few unchanged
///   graphemes apart, or in one word, merge into one span: one jump in, the span, one jump out.
/// - Mode: a span goes in as minimal character edits (the differing characters only, with short moves between them)
///   or as one block delete and its new text typed, whichever the cost estimate says is quicker; a tie keeps the
///   minimal edits.
/// - Pace: one grapheme per op. The gap between typed graphemes spreads the work over about `budgetMs`, no slower
///   than `calmMs` and no faster than the field's confirmation (`floorMs`).
public enum SpanPlanner {
    /// A change of `old[start..<end]` into `text` (grapheme offsets into the old text).
    public struct Hunk: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public var text: [Character]
        public init(start: Int, end: Int, text: [Character]) { self.start = start; self.end = end; self.text = text }
    }

    public struct Span: Sendable, Equatable {
        /// Old text `start..<end` becomes `text`.
        public var start: Int
        public var end: Int
        public var text: [Character]
        /// One delete of `start..<end`, then `text` typed; otherwise `hunks` (inside the span) one by one.
        public var block: Bool
        public var hunks: [Hunk]
    }

    /// Changes this many unchanged graphemes apart (or fewer) merge into one span.
    public static let mergeGap = 3
    /// A word whose graphemes change by this share or more is replaced whole.
    public static let wordShare = 0.5

    // MARK: Pace

    /// A short change types at this calm pace.
    public static let calmMs = 65.0
    /// The field's confirmation: the keyboard reads one report per 33 ms tick, and Safari leaves its report stale after
    /// edits sent back to back (spike), so typed graphemes are never closer than this.
    public static let floorMs = 30.0
    /// What a change, or the backlog, aims to take.
    public static let budgetMs = 1_200.0

    /// The gap between typed graphemes for `ops` of them still to go, after `fixedMs` of settles the work needs anyway:
    /// spread over the budget, between the floor and the calm pace.
    public static func paceMs(ops: Int, fixedMs: Double = 0) -> Double {
        guard ops > 0 else { return calmMs }
        return min(calmMs, max(floorMs, (budgetMs - fixedMs) / Double(ops)))
    }

    // MARK: Spans

    /// The spans that turn `old` into `new`, back to front order is the caller's. `leaveTailAppend`: growth at the very
    /// end is left out (the typewriter types it). The cost estimate uses `paceMs` per typed grapheme (0: typed in one
    /// op) and the queue's settles.
    public static func spans(from old: [Character], to new: [Character], leaveTailAppend: Bool = false,
                             paceMs: Double = calmMs, moveSettleMs: Double, editSettleMs: Double) -> [Span] {
        var hunks = ShadowEditPlanner.diff(old, new).map { Hunk(start: $0.start, end: $0.end, text: $0.text) }
        if leaveTailAppend, let last = hunks.last, last.start == old.count, last.end == old.count { hunks.removeLast() }
        guard !hunks.isEmpty else { return [] }
        hunks = snapToWords(hunks, old: old, new: new)
        return merge(hunks, old: old).map { group in
            let start = group.first!.start, end = group.last!.end
            let text = Array(new[map(start, hunks: hunks, side: .start)..<map(end, hunks: hunks, side: .end)])
            let minimal = cost(of: group, paceMs: paceMs, moveSettleMs: moveSettleMs, editSettleMs: editSettleMs)
            let block = cost(of: [Hunk(start: start, end: end, text: text)], paceMs: paceMs, moveSettleMs: moveSettleMs,
                             editSettleMs: editSettleMs)
            return Span(start: start, end: end, text: text, block: group.count > 1 && block < minimal, hunks: group)
        }
    }

    /// The time hunks take: a move between them (an edit's settle, then the move's), one op per deletion, a settle
    /// where a delete is followed by typing, and one op per typed grapheme (or one op for all at pace 0).
    static func cost(of hunks: [Hunk], paceMs: Double, moveSettleMs: Double, editSettleMs: Double) -> Double {
        let op = max(paceMs, floorMs)
        var ms = 0.0
        for (i, h) in hunks.enumerated() {
            if i > 0 { ms += editSettleMs + moveSettleMs }
            if h.end > h.start { ms += op }
            if h.end > h.start, !h.text.isEmpty { ms += editSettleMs }
            if !h.text.isEmpty { ms += paceMs > 0 ? Double(h.text.count) * paceMs : op }
        }
        return ms
    }

    private enum Side { case start, end }

    /// Where old offset `x` lands in the new text; at a change's edge, before (`start`) or after (`end`) its new text.
    private static func map(_ x: Int, hunks: [Hunk], side: Side) -> Int {
        var shift = 0
        for h in hunks {
            if h.end < x || (h.end == x && (side == .end || h.start < h.end)) { shift += h.text.count - (h.end - h.start) }
            else if h.start < x { return h.start + shift + h.text.count }
            else { break }
        }
        return x + shift
    }

    private static func inWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" }

    /// The word around `range` of `text`: the range grown through word characters on both sides.
    private static func word(around range: Range<Int>, in text: [Character]) -> Range<Int> {
        var a = range.lowerBound, b = range.upperBound
        while a > 0, inWord(text[a - 1]) { a -= 1 }
        while b < text.count, inWord(text[b]) { b += 1 }
        return a..<b
    }

    /// A word that loses and gains graphemes, at least `wordShare` of it either way, becomes one change of the whole
    /// word. Pure insertions or deletions stay as they are (deleting a whole word to type it again saves nothing).
    private static func snapToWords(_ hunks: [Hunk], old: [Character], new: [Character]) -> [Hunk] {
        var result: [Hunk] = []
        var i = 0
        while i < hunks.count {
            let w = word(around: hunks[i].start..<hunks[i].end, in: old)
            var j = i
            while j + 1 < hunks.count, hunks[j + 1].start <= w.upperBound { j += 1 }
            let inside = hunks[i...j]
            let deleted = inside.reduce(0) { $0 + $1.end - $1.start }
            let typed = inside.reduce(0) { $0 + $1.text.count }
            let wordStart = max(min(w.lowerBound, inside.first!.start), result.last?.end ?? 0)
            let wordEnd = max(w.upperBound, inside.last!.end)
            let newStart = map(wordStart, hunks: hunks, side: .start), newEnd = map(wordEnd, hunks: hunks, side: .end)
            let oldCount = wordEnd - wordStart, newCount = newEnd - newStart
            let share = max(Double(deleted) / Double(max(1, oldCount)), Double(typed) / Double(max(1, newCount)))
            if deleted > 0, typed > 0, share >= wordShare {
                result.append(Hunk(start: wordStart, end: wordEnd, text: Array(new[newStart..<newEnd])))
            } else {
                result += inside
            }
            i = j + 1
        }
        return result
    }

    /// Changes a few unchanged graphemes apart, or in one word, form one span.
    private static func merge(_ hunks: [Hunk], old: [Character]) -> [[Hunk]] {
        var groups: [[Hunk]] = []
        for h in hunks {
            if let last = groups.last?.last {
                let between = old[last.end..<h.start]
                if between.count <= mergeGap || between.allSatisfy(inWord) { groups[groups.count - 1].append(h); continue }
            }
            groups.append([h])
        }
        return groups
    }
}
