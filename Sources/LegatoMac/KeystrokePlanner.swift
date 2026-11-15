import Foundation
import LegatoKeyboardCore

/// Plans how a change of a region's text goes into a field that takes keystrokes (Chromium web content), and at what
/// pace. Pure. The same rules as the iOS keyboard's span planner:
///
/// - Spans share the exact desktop grapheme diff. Nearby changes share jumps, while unchanged letters, spaces
///   and punctuation remain in the host. Cost estimates never broaden a replacement into a whole word or block.
/// - Pace: one grapheme per key. The gap between typed graphemes spreads the work over about `budgetMs`, no slower than
///   `calmMs` and no faster than `floorMs`; a backlog of `behindOps` or more goes at the floor.
public enum KeystrokePlanner {
    public typealias Hunk = SpanPlanner.Hunk
    public typealias Span = SpanPlanner.Span

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
    public static let mergeGap = SpanPlanner.mergeGap
    /// A word whose graphemes change by this share or more is replaced whole.
    public static let wordShare = SpanPlanner.wordShare

    // MARK: Pace

    /// The trial types short changes at the same 5 ms pace as queued changes.
    public static let calmMs = SpanPlanner.calmMs
    /// Typed graphemes in a keystroke field are never closer than this (each key also waits for its read-back).
    public static let floorMs = SpanPlanner.floorMs
    /// The same 5 ms trial for an Accessibility-writable field.
    public static let writeFloorMs = SpanPlanner.floorMs
    /// What a change, or the backlog, aims to take.
    public static let budgetMs = SpanPlanner.budgetMs
    /// This many graphemes still to type (a change's, plus what dictation has queued behind it) mean typing has fallen
    /// behind speech (about 15 characters a second): the pace goes straight to the floor.
    public static let behindOps = SpanPlanner.behindOps
    /// About what one verified key costs (send, the host applies it, the read-back shows it).
    public static let keyMs = 15.0
    /// The pause at a transition between moves and edits (the host may apply either late).
    public static let settleMs = 5.0
    /// About what a verified jump costs at any distance: an Accessibility caret set, or a few hops and a short run of
    /// arrows (the default, until the field showed which works).
    public static let jumpMs = 3 * keyMs

    /// The time a caret move of `distance` graphemes takes: arrows, or one jump when that is cheaper.
    public static func moveMs(_ distance: Int, jumpMs: Double = jumpMs) -> Double {
        distance <= 0 ? 0 : min(Double(distance) * keyMs, jumpMs)
    }

    /// The gap between typed graphemes for `ops` of them still to go, after `fixedMs` of keys and settles the work
    /// needs anyway: spread over the budget, between the floor and the calm pace; straight to the floor once `ops`
    /// reaches `behindOps`.
    public static func paceMs(ops: Int, fixedMs: Double = 0, floor: Double = floorMs) -> Double {
        SpanPlanner.macPaceMs(ops: ops, fixedMs: fixedMs, floor: floor)
    }

    // MARK: Spans

    /// The spans that turn `old` into `new`, front to back.
    public static func spans(from old: [Character], to new: [Character], paceMs: Double = calmMs, jumpMs: Double = jumpMs) -> [Span] {
        SpanPlanner.spans(from: old, to: new, paceMs: paceMs, moveSettleMs: settleMs, editSettleMs: settleMs)
    }

    /// The edit keys that turn `old` into `new`: spans back to front (so earlier offsets hold), in each the hunks back to
    /// front, each hunk's Backspaces from its end, then its new graphemes typed in order.
    ///
    /// A replacement that would empty its line first keeps the line's first old grapheme, types the new text before
    /// it, and deletes it last: a rich editor puts a placeholder line break into a line that becomes empty, and drops
    /// it again, so the line is never left empty. `lineStart` / `lineEnd`: the text starts / ends a line of the field.
    public static func steps(from old: [Character], to new: [Character], paceMs: Double = calmMs, jumpMs: Double = jumpMs,
                             lineStart: Bool = true, lineEnd: Bool = true) -> [Step] {
        var steps: [Step] = []
        var text = old
        func add(_ caret: Int, _ key: Step.Key) {
            let step = Step(caret: caret, key: key, before: text)
            text = step.after; steps.append(step)
        }
        for span in spans(from: old, to: new, paceMs: paceMs, jumpMs: jumpMs).reversed() {
            let hunks = span.block ? [Hunk(start: span.start, end: span.end, text: span.text)] : span.hunks
            for hunk in hunks.reversed() {
                let emptiesLine = hunk.end > hunk.start && !hunk.text.isEmpty
                    && (hunk.start == 0 ? lineStart : text[hunk.start - 1].isNewline)
                    && (hunk.end == text.count ? lineEnd : text[hunk.end].isNewline)
                let kept = emptiesLine ? 1 : 0
                var caret = hunk.end
                while caret > hunk.start + kept { add(caret, .backspace); caret -= 1 }
                caret = hunk.start
                for character in hunk.text { add(caret, .type(character)); caret += 1 }
                if emptiesLine { add(caret + 1, .backspace) }
            }
        }
        return steps
    }

    /// The time hunks take, back to front: a caret move from one hunk's typed end to the next hunk's end (`moveMs`), a
    /// settle at each move/edit transition, one key per deleted grapheme, one paced key per typed grapheme.
    static func cost(of hunks: [Hunk], paceMs: Double, jumpMs: Double = jumpMs) -> Double {
        let typed = max(paceMs, floorMs)
        var ms = 0.0
        var previous: Hunk?
        for hunk in hunks.reversed() {
            if let previous {
                let arrows = previous.start + previous.text.count - hunk.end
                ms += moveMs(arrows, jumpMs: jumpMs) + 2 * settleMs
            }
            ms += Double(hunk.end - hunk.start) * keyMs
            ms += Double(hunk.text.count) * typed
            previous = hunk
        }
        return ms
    }

}
