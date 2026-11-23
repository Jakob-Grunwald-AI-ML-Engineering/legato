import Foundation

/// One step against the text proxy. Spike: pure planner for word-level edits anywhere in a mirrored field.
public enum ShadowOp: Sendable, Equatable {
    /// `adjustTextPosition(byCharacterOffset:)`, in UTF-16 units (the unit the proxy moves by).
    case move(Int)
    /// `deleteBackward()` this many times (one per Character).
    case deleteBackward(Int)
    case insert(String)
}

public struct ShadowPlan: Sendable, Equatable {
    public var ops: [ShadowOp]
    /// Cursor (UTF-16 offset into the target text) once the ops ran.
    public var cursor: Int
    public init(ops: [ShadowOp], cursor: Int) {
        self.ops = ops
        self.cursor = cursor
    }
}

/// The changed and surviving graphemes for a draft preview's Magic transition.
public struct PreviewRewriteDiff: Equatable, Sendable {
    public let removed: Set<Int>
    public let inserted: Set<Int>
    /// The original index of each surviving grapheme, keyed by its new index.
    public let survivors: [Int: Int]

    public init(original: String, target: String) {
        let before = Array(original), after = Array(target)
        let changes = ShadowEditPlanner.diff(before, after, previewBudget: 360_000)
        var removed: Set<Int> = [], inserted: Set<Int> = []
        var shift = 0
        for change in changes {
            removed.formUnion(change.start..<change.end)
            let next = change.start + shift
            inserted.formUnion(next..<(next + change.text.count))
            shift += change.text.count - (change.end - change.start)
        }
        self.removed = removed
        self.inserted = inserted
        survivors = Dictionary(uniqueKeysWithValues: zip(after.indices.lazy.filter { !inserted.contains($0) },
                                                          before.indices.lazy.filter { !removed.contains($0) }))
    }
}

/// Exact minimal insertion/deletion diff over extended grapheme clusters. Unchanged characters
/// stay in the host, including whitespace and punctuation. Cursor moves use UTF-16 units.
public enum ShadowEditPlanner {
    /// `cursor` is a UTF-16 offset. `characters` emits one deletion or insertion per grapheme;
    /// otherwise adjacent changed characters may share an operation. `coarse` has no effect.
    public static func plan(shadow: String, cursor: Int, target: String, coarse: Bool = false, characters: Bool = false) -> ShadowPlan {
        let old = Array(shadow), new = Array(target)
        let cursorIndex = characterIndex(ofUTF16: cursor, in: old)
        let fine = diff(old, new)

        // Logical cursor in the new text.
        var shift = 0
        var newCursor: Int?
        for h in fine {
            if cursorIndex < h.start || (cursorIndex == h.start && h.end > h.start) { break }
            if cursorIndex <= h.end { newCursor = h.start + shift + h.text.count; break }
            shift += h.text.count - (h.end - h.start)
        }
        let newCursorIndex = newCursor ?? cursorIndex + shift
        // The cursor's place comes from the word-level hunks; merged hunks only change how the text gets there.
        let hunks = fine // `coarse` is retained for source compatibility; it never retypes unchanged text.

        var doc = old
        var at = cursorIndex
        var ops: [ShadowOp] = []
        func move(to index: Int) {
            guard index != at else { return }
            let range = index > at ? at..<index : index..<at
            let units = String(doc[range]).utf16.count
            let delta = index > at ? units : -units
            if case .move(let last)? = ops.last { ops[ops.count - 1] = .move(last + delta) } else { ops.append(.move(delta)) }
            at = index
        }
        for h in hunks.reversed() {
            move(to: h.end)
            if h.end > h.start {
                if characters { ops += (h.start..<h.end).map { _ in .deleteBackward(1) } }
                else { ops.append(.deleteBackward(h.end - h.start)) }
                doc.removeSubrange(h.start..<h.end)
                at = h.start
            }
            if !h.text.isEmpty {
                if characters { ops += h.text.map { .insert(String($0)) } } else { ops.append(.insert(String(h.text))) }
                doc.insert(contentsOf: h.text, at: at)
                at += h.text.count
            }
        }
        move(to: newCursorIndex)
        ops = ops.filter { $0 != .move(0) }
        return ShadowPlan(ops: ops, cursor: String(new.prefix(newCursorIndex)).utf16.count)
    }

    /// The edit as ops at the end of `shadow` (the cursor there): delete back to the first character that differs and
    /// type the rest of `target` (one character per insert with `characters`). Nil when more than `limit` characters
    /// would be deleted, or nothing differs.
    public static func retypeTail(shadow: String, target: String, limit: Int, characters: Bool = false) -> [ShadowOp]? {
        let old = Array(shadow), new = Array(target)
        guard old != new else { return nil }
        var common = 0
        while common < min(old.count, new.count), old[common] == new[common] { common += 1 }
        let deleted = old.count - common
        guard deleted <= limit else { return nil }
        var ops: [ShadowOp] = []
        if deleted > 0 { ops.append(.deleteBackward(deleted)) }
        if common < new.count {
            if characters { ops += new[common...].map { .insert(String($0)) } } else { ops.append(.insert(String(new[common...]))) }
        }
        return ops
    }

    /// `shadow` with only the word-level changes toward `target` that start within its last `window` characters (the
    /// rest stays as it is).
    public static func endGoal(shadow: String, target: String, window: Int) -> String {
        let old = Array(shadow)
        var doc = old
        for h in diff(old, Array(target)).reversed() where h.start >= old.count - window {
            doc.replaceSubrange(h.start..<h.end, with: h.text)
        }
        return String(doc)
    }

    /// Runs `ops` against a model of the proxy (text + UTF-16 cursor), the way the keyboard would.
    public static func simulate(ops: [ShadowOp], shadow: String, cursor: Int) -> (text: String, cursor: Int) {
        var doc = Array(shadow)
        var at = characterIndex(ofUTF16: cursor, in: doc)
        for op in ops {
            switch op {
            case .move(let units):
                var remaining = abs(units)
                while remaining > 0 {
                    if units > 0 { guard at < doc.count else { break }; remaining -= String(doc[at]).utf16.count; at += 1 }
                    else { guard at > 0 else { break }; remaining -= String(doc[at - 1]).utf16.count; at -= 1 }
                }
            case .deleteBackward(let n):
                let k = min(n, at)
                doc.removeSubrange((at - k)..<at)
                at -= k
            case .insert(let s):
                doc.insert(contentsOf: s, at: at)
                at += s.count
            }
        }
        return (String(doc), String(doc.prefix(at)).utf16.count)
    }

    // MARK: Diff

    /// One change of the minimal diff: the characters `start..<end` of the old text become `text`.
    public struct Change: Sendable, Equatable {
        public var start: Int
        public var end: Int
        public var text: [Character]
        public init(start: Int, end: Int, text: [Character]) { self.start = start; self.end = end; self.text = text }
    }

    /// The minimal grapheme diff from `old` to `new`, in order: only the differing characters.
    public static func changes(from old: [Character], to new: [Character]) -> [Change] {
        diff(old, new).map { Change(start: $0.start, end: $0.end, text: $0.text) }
    }

    struct Hunk { var start: Int; var end: Int; var text: [Character] }

    /// Hirschberg LCS: exact shortest edit script, linear auxiliary memory. Common boundaries
    /// and disjoint alphabets avoid the quadratic work for typical streaming appends and rewrites.
    static func diff(_ old: [Character], _ new: [Character], previewBudget: Int? = nil) -> [Hunk] {
        var remaining = previewBudget ?? 0
        var pairs: [(Int, Int)] = []
        func lengths(_ ar: Range<Int>, _ br: Range<Int>, reversed: Bool) -> [Int] {
            var row = [Int](repeating: 0, count: br.count + 1)
            for ai in 0..<ar.count {
                let a = old[reversed ? ar.upperBound - 1 - ai : ar.lowerBound + ai]
                var diagonal = 0
                for bi in 0..<br.count {
                    let previous = row[bi + 1]
                    let b = new[reversed ? br.upperBound - 1 - bi : br.lowerBound + bi]
                    row[bi + 1] = a == b ? diagonal + 1 : max(row[bi], previous)
                    diagonal = previous
                }
            }
            return row
        }
        // For large previews, find unique unchanged windows and spend the exact diff budget between them.
        // The source windows never overlap, so we can use increasing matches without moving text backwards.
        let window = 12
        func anchors(_ ar: Range<Int>, _ br: Range<Int>) -> [(Int, Int)] {
            guard ar.count >= window, br.count >= window else { return [] }
            var source: [String: Int] = [:]
            for start in stride(from: ar.lowerBound, through: ar.upperBound - window, by: window) {
                let key = String(old[start..<(start + window)])
                source[key] = source[key] == nil ? start : -1
            }
            var target: [Int: Int] = [:]
            for start in br.lowerBound...(br.upperBound - window) {
                if let index = source[String(new[start..<(start + window)])], index >= 0 {
                    target[index] = target[index] == nil ? start : -1
                }
            }
            var next = br.lowerBound
            var matches: [(Int, Int)] = []
            for index in target.keys.sorted() {
                guard let start = target[index], start >= next else { continue }
                matches.append((index, start))
                next = start + window
            }
            return matches
        }
        func match(_ ar: Range<Int>, _ br: Range<Int>, exact: Bool, searchAnchors: Bool = true) {
            var lo = ar.lowerBound, ln = br.lowerBound
            var hi = ar.upperBound, hn = br.upperBound
            while lo < hi, ln < hn, old[lo] == new[ln] { pairs.append((lo, ln)); lo += 1; ln += 1 }
            var suffix = 0
            while lo < hi, ln < hn, old[hi - 1] == new[hn - 1] { hi -= 1; hn -= 1; suffix += 1 }
            if lo < hi, ln < hn {
                if hi - lo == 1 {
                    if let j = (ln..<hn).first(where: { new[$0] == old[lo] }) { pairs.append((lo, j)) }
                } else if !Set(old[lo..<hi]).isDisjoint(with: new[ln..<hn]) {
                    let width = hn - ln
                    if exact || hi - lo <= remaining / width {
                        if !exact { remaining -= (hi - lo) * width }
                        let mid = lo + (hi - lo) / 2
                        // Keep the row buffers outside recursive frames: auxiliary storage stays linear.
                        let split: Int = {
                            let left = lengths(lo..<mid, ln..<hn, reversed: false)
                            let right = lengths(mid..<hi, ln..<hn, reversed: true)
                            var best = 0, score = -1
                            for j in 0...(hn - ln) {
                                let candidate = left[j] + right[hn - ln - j]
                                if candidate > score { score = candidate; best = j }
                            }
                            return ln + best
                        }()
                        match(lo..<mid, ln..<split, exact: true)
                        match(mid..<hi, split..<hn, exact: true)
                    } else if searchAnchors {
                        var oldStart = lo, newStart = ln
                        for (oldIndex, newIndex) in anchors(lo..<hi, ln..<hn) {
                            match(oldStart..<oldIndex, newStart..<newIndex, exact: false, searchAnchors: false)
                            for offset in 0..<window { pairs.append((oldIndex + offset, newIndex + offset)) }
                            oldStart = oldIndex + window
                            newStart = newIndex + window
                        }
                        match(oldStart..<hi, newStart..<hn, exact: false, searchAnchors: false)
                    }
                }
            }
            for k in 0..<suffix { pairs.append((hi + k, hn + k)) }
        }
        match(0..<old.count, 0..<new.count, exact: previewBudget == nil)
        var hunks: [Hunk] = []
        var po = 0, pn = 0
        for (mo, mn) in pairs + [(old.count, new.count)] {
            if mo > po || mn > pn { hunks.append(Hunk(start: po, end: mo, text: Array(new[pn..<mn]))) }
            po = mo + 1; pn = mn + 1
        }
        return hunks
    }

    static func characterIndex(ofUTF16 offset: Int, in chars: [Character]) -> Int {
        var units = 0
        for (i, c) in chars.enumerated() {
            if units >= offset { return i }
            units += String(c).utf16.count
        }
        return chars.count
    }
}
