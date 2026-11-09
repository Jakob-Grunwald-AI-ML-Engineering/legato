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

/// Word-level diff of a mirrored field against a target text, as proxy ops. The field is tokenized into
/// words, whitespace runs and single punctuation marks; an LCS over tokens picks the tokens that stay;
/// the rest becomes hunks, applied back-to-front so earlier offsets stay valid. The cursor goes back to
/// its logical place: shifted by edits before it, at the end of the replacement when it sat inside one.
///
/// `coarse` (an instruction's rewrite, where every op is one round trip to a slow host): neighbouring hunks with at most
/// `mergeGapWords` unchanged words between them become one replace, and when more than `wholeShare` of the words
/// change, everything from the first change to the last is one delete and one insert. A small edit stays word-level.
public enum ShadowEditPlanner {
    public static let mergeGapWords = 3
    public static let wholeShare = 0.5

    /// - Parameters:
    ///   - cursor: UTF-16 offset into `shadow` (clamped).
    ///   - coarse: see the type's note (instruction edits).
    ///   - characters: refine each changed word span to the characters that differ (a character-level diff inside
    ///     it), and insert one character per op: a typewriter edit of only what changed ("whether" to "weather"
    ///     deletes "h" and inserts "a"). Live flips only; not combined with `coarse`.
    public static func plan(shadow: String, cursor: Int, target: String, coarse: Bool = false, characters: Bool = false) -> ShadowPlan {
        let old = Array(shadow), new = Array(target)
        let cursorIndex = characterIndex(ofUTF16: cursor, in: old)
        let words = diff(old, new)
        let fine = characters ? words.flatMap { refine($0, old: old) } : words

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
        let hunks = coarse ? merged(fine, old: old) : fine

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
                ops.append(.deleteBackward(h.end - h.start))
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

    struct Hunk { var start: Int; var end: Int; var text: [Character] }

    enum TokenClass { case word, space, mark }

    static func tokenize(_ chars: [Character]) -> [(range: Range<Int>, text: String)] {
        func cls(_ c: Character) -> TokenClass {
            if c.isWhitespace { return .space }
            if c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" { return .word }
            return .mark
        }
        var out: [(Range<Int>, String)] = []
        var i = 0
        while i < chars.count {
            let k = cls(chars[i])
            var j = i + 1
            if k != .mark { while j < chars.count, cls(chars[j]) == k { j += 1 } }
            out.append((i..<j, String(chars[i..<j])))
            i = j
        }
        return out
    }

    static func diff(_ old: [Character], _ new: [Character]) -> [Hunk] {
        if old == new { return [] }
        let a = tokenize(old), b = tokenize(new)
        var pre = 0
        while pre < a.count, pre < b.count, a[pre].text == b[pre].text { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf].text == b[b.count - 1 - suf].text { suf += 1 }
        let n = a.count - pre - suf, m = b.count - pre - suf
        // LCS table over the differing middle.
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[pre + i].text == b[pre + j].text ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        // Matched token pairs (old index, new index), including the common prefix/suffix.
        var pairs: [(Int, Int)] = (0..<pre).map { ($0, $0) }
        var i = 0, j = 0
        while i < n, j < m {
            if a[pre + i].text == b[pre + j].text { pairs.append((pre + i, pre + j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        for k in 0..<suf { pairs.append((a.count - suf + k, b.count - suf + k)) }

        func oldStart(_ t: Int) -> Int { t < a.count ? a[t].range.lowerBound : old.count }
        func newStart(_ t: Int) -> Int { t < b.count ? b[t].range.lowerBound : new.count }
        var hunks: [Hunk] = []
        var po = 0, pn = 0 // next unmatched token indices
        for (mo, mn) in pairs + [(a.count, b.count)] {
            if mo > po || mn > pn {
                hunks.append(Hunk(start: oldStart(po), end: oldStart(mo), text: Array(new[newStart(pn)..<newStart(mn)])))
            }
            po = mo + 1; pn = mn + 1
        }
        return hunks
    }

    /// Hunks joined into fewer replaces (see `coarse`); the unchanged text between two joined hunks is retyped.
    static func merged(_ hunks: [Hunk], old: [Character]) -> [Hunk] {
        guard hunks.count > 1, let first = hunks.first else { return hunks }
        func words(_ range: Range<Int>) -> Int {
            tokenize(Array(old[range])).filter { $0.text.first.map { $0.isLetter || $0.isNumber } == true }.count
        }
        func join(_ a: Hunk, _ b: Hunk) -> Hunk { Hunk(start: a.start, end: b.end, text: a.text + old[a.end..<b.start] + b.text) }
        let total = words(0..<old.count)
        let changed = hunks.reduce(0) { $0 + words($1.start..<$1.end) }
        // Mostly rewritten (or only inserted into): one replace from the first change to the last.
        if total == 0 || Double(changed) > Double(total) * wholeShare { return [hunks.dropFirst().reduce(first, join)] }
        var out = [first]
        for h in hunks.dropFirst() {
            if words(out[out.count - 1].end..<h.start) <= mergeGapWords { out[out.count - 1] = join(out[out.count - 1], h) } else { out.append(h) }
        }
        return out
    }

    /// A word-level hunk split into the character runs that differ (an LCS over its characters), positions in `old`.
    static func refine(_ hunk: Hunk, old: [Character]) -> [Hunk] {
        let a = Array(old[hunk.start..<hunk.end]), b = hunk.text
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 40_000 else { return [hunk] }
        let n = a.count, m = b.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Hunk] = []
        var i = 0, j = 0, pi = 0, pj = 0
        func close(_ mi: Int, _ mj: Int) {
            if mi > pi || mj > pj { out.append(Hunk(start: hunk.start + pi, end: hunk.start + mi, text: Array(b[pj..<mj]))) }
        }
        while i < n, j < m {
            if a[i] == b[j] { close(i, j); i += 1; j += 1; pi = i; pj = j }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        close(n, m)
        return out
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
