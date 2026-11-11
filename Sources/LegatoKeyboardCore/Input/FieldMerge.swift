import Foundation

/// Three-way merge of one text two writers changed from the same base. Pure.
///
/// - `kept` wins: an `incoming` change that touches a word `kept` changed is dropped (counted), every other incoming
///   change is carried onto `kept`. Incoming changes are word-snapped like the queue's spans (`SpanPlanner`).
/// - Touching: overlapping a changed word; an insertion inside one, at the place `kept` inserted text too, glued onto
///   its word (a letter right at it), or next to words `kept` deleted whole. Punctuation after a word the user only
///   shortened still lands ("afterno" + "." → "afterno.").
/// - The queue uses it for a dictation region the user edited (kept: the field, incoming: the run's new text) and for
///   Magic over text Legato changed since the read (kept: Magic's result, incoming: the scope as Legato left it).
enum FieldMerge {
    struct Result: Equatable {
        var text: [Character]
        /// Incoming changes that touched kept's and were dropped.
        var dropped: Int
    }

    /// `keptHunks`: kept's changes when known exactly (who wrote each character); else the diff, which can take a
    /// repeated letter for the other writer's.
    static func rebase(base: [Character], kept: [Character], incoming: [Character],
                       keptHunks known: [ShadowEditPlanner.Hunk]? = nil) -> Result {
        guard incoming != base else { return Result(text: kept, dropped: 0) }
        guard kept != base else { return Result(text: incoming, dropped: 0) }
        let keptHunks = known ?? ShadowEditPlanner.diff(base, kept)
        let zones = keptHunks.map { zone(of: $0, in: base) }
        var text = kept
        var dropped = 0
        for h in SpanPlanner.wordHunks(from: base, to: incoming).reversed() {
            if zones.contains(where: { touches(h, $0) }) { dropped += 1; continue }
            let start = map(h.start, through: keptHunks, after: true)
            let end = h.start == h.end ? start : max(start, map(h.end, through: keptHunks, after: false))
            text.replaceSubrange(start..<end, with: h.text)
        }
        return Result(text: text, dropped: dropped)
    }

    // MARK: Private

    private struct Zone {
        /// The words kept changed (base offsets).
        var start: Int
        var end: Int
        /// The raw change.
        var hunk: ShadowEditPlanner.Hunk
        /// Kept deleted these words whole.
        var gone: Bool
    }

    private static func inWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" }

    /// The words a kept change touches: grown through word characters on a side where the change joins a word.
    private static func zone(of h: ShadowEditPlanner.Hunk, in base: [Character]) -> Zone {
        var a = h.start, b = h.end
        let deletes = h.end > h.start
        if a > 0, inWord(base[a - 1]), deletes ? inWord(base[a]) : (h.text.first.map(inWord) ?? false) {
            while a > 0, inWord(base[a - 1]) { a -= 1 }
        }
        if b < base.count, inWord(base[b]), deletes ? inWord(base[b - 1]) : (h.text.last.map(inWord) ?? false) {
            while b < base.count, inWord(base[b]) { b += 1 }
        }
        return Zone(start: a, end: b, hunk: h, gone: deletes && h.text.isEmpty && a == h.start && b == h.end)
    }

    private static func touches(_ h: SpanPlanner.Hunk, _ z: Zone) -> Bool {
        if h.start < h.end {
            if h.start < z.end, z.start < h.end { return true }
            return z.start == z.end && h.start < z.start && z.start < h.end
        }
        let x = h.start
        if z.start < x, x < z.end { return true }
        // Both insert here: which goes first is anyone's guess.
        if !z.hunk.text.isEmpty, z.hunk.start == x || z.hunk.end == x { return true }
        guard x == z.start || x == z.end else { return false }
        if z.gone { return true }
        // Glued onto the changed word.
        if x == z.end, z.end > z.start, h.text.first.map(inWord) == true { return true }
        if x == z.start, z.end > z.start, h.text.last.map(inWord) == true { return true }
        return false
    }

    /// Where base offset `x` lands in kept; at a pure insertion of kept's right there, after it (`after`) or before.
    private static func map(_ x: Int, through hunks: [ShadowEditPlanner.Hunk], after: Bool) -> Int {
        var shift = 0
        for h in hunks {
            if h.end < x || (h.end == x && (h.start < h.end || after)) { shift += h.text.count - (h.end - h.start) }
            else if h.start < x { return h.start + shift + h.text.count }
            else { break }
        }
        return x + shift
    }
}
