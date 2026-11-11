import Foundation
import LegatoKeyboardCore

/// Plans how a change of a region's text goes into a field that takes keystrokes (Chromium web content), and at what
/// pace. Pure. The same rules as the iOS keyboard's span planner:
///
/// - Spans: the minimal grapheme diff; a word whose graphemes change by at least half is replaced whole ("Thursday" →
///   "Friday"; "colour" → "color" stays one deleted letter); changes a few unchanged graphemes apart, or in one word,
///   merge into one span.
/// - Mode: a span goes in as minimal edits (the differing characters only, with arrow moves between them) or as one
///   block delete and its new text typed, whichever costs less; a tie keeps the minimal edits.
/// - Pace: one grapheme per key. The gap between typed graphemes spreads the work over about `budgetMs`, no slower than
///   `calmMs` and no faster than `floorMs`.
public enum KeystrokePlanner {
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
        /// One block delete of `start..<end`, then `text` typed; otherwise `hunks` one by one.
        public var block: Bool
        public var hunks: [Hunk]
    }

    /// One edit key: with the caret at grapheme `caret` of `before`, Backspace or one typed grapheme.
    public struct Step: Sendable, Equatable {
        public enum Key: Sendable, Equatable { case backspace, type(Character) }
        public var caret: Int
        public var key: Key
        /// The text before and after the key.
        public var before: [Character]
        public var after: [Character] {
            var text = before
            switch key {
            case .backspace: text.remove(at: caret - 1)
            case .type(let character): text.insert(character, at: caret)
            }
            return text
        }
        /// The caret after the key.
        public var caretAfter: Int { if case .backspace = key { caret - 1 } else { caret + 1 } }
    }

    /// Changes this many unchanged graphemes apart (or fewer) merge into one span.
    public static let mergeGap = 3
    /// A word whose graphemes change by this share or more is replaced whole.
    public static let wordShare = 0.5

    // MARK: Pace

    /// A short change types at this calm pace.
    public static let calmMs = 65.0
    /// Typed graphemes are never closer than this (each key also waits for its read-back).
    public static let floorMs = 12.0
    /// What a change, or the backlog, aims to take.
    public static let budgetMs = 1_200.0
    /// About what one verified key costs (send, the host applies it, the read-back shows it).
    public static let keyMs = 15.0
    /// The pause at a transition between moves and edits (the host may apply either late).
    public static let settleMs = 30.0

    /// The gap between typed graphemes for `ops` of them still to go, after `fixedMs` of keys and settles the work
    /// needs anyway: spread over the budget, between the floor and the calm pace.
    public static func paceMs(ops: Int, fixedMs: Double = 0) -> Double {
        guard ops > 0 else { return calmMs }
        return min(calmMs, max(floorMs, (budgetMs - fixedMs) / Double(ops)))
    }

    // MARK: Spans

    /// The spans that turn `old` into `new`, front to back.
    public static func spans(from old: [Character], to new: [Character], paceMs: Double = calmMs) -> [Span] {
        var hunks = ShadowEditPlanner.changes(from: old, to: new).map { Hunk(start: $0.start, end: $0.end, text: $0.text) }
        guard !hunks.isEmpty else { return [] }
        hunks = snapToWords(hunks, old: old, new: new)
        return merge(hunks, old: old).map { group in
            let start = group.first!.start, end = group.last!.end
            let text = Array(new[map(start, hunks: hunks, side: .start)..<map(end, hunks: hunks, side: .end)])
            let minimal = cost(of: group, paceMs: paceMs)
            let block = cost(of: [Hunk(start: start, end: end, text: text)], paceMs: paceMs)
            return Span(start: start, end: end, text: text, block: group.count > 1 && block < minimal, hunks: group)
        }
    }

    /// The edit keys that turn `old` into `new`: spans back to front (so earlier offsets hold), in each the hunks back to
    /// front, each hunk's Backspaces from its end, then its new graphemes typed in order.
    public static func steps(from old: [Character], to new: [Character], paceMs: Double = calmMs) -> [Step] {
        var steps: [Step] = []
        var text = old
        for span in spans(from: old, to: new, paceMs: paceMs).reversed() {
            let hunks = span.block ? [Hunk(start: span.start, end: span.end, text: span.text)] : span.hunks
            for hunk in hunks.reversed() {
                var caret = hunk.end
                while caret > hunk.start {
                    let step = Step(caret: caret, key: .backspace, before: text)
                    text = step.after; caret -= 1; steps.append(step)
                }
                for character in hunk.text {
                    let step = Step(caret: caret, key: .type(character), before: text)
                    text = step.after; caret += 1; steps.append(step)
                }
            }
        }
        return steps
    }

    /// The time hunks take, back to front: arrows from one hunk's typed end to the next hunk's end, a settle at each
    /// move/edit transition, one key per deleted grapheme, one paced key per typed grapheme.
    static func cost(of hunks: [Hunk], paceMs: Double) -> Double {
        let typed = max(paceMs, floorMs)
        var ms = 0.0
        var previous: Hunk?
        for hunk in hunks.reversed() {
            if let previous {
                let arrows = previous.start + previous.text.count - hunk.end
                ms += Double(max(0, arrows)) * keyMs + 2 * settleMs
            }
            ms += Double(hunk.end - hunk.start) * keyMs
            ms += Double(hunk.text.count) * typed
            previous = hunk
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
