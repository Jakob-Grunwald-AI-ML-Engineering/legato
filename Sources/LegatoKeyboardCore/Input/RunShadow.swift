import Foundation

/// The keyboard's model of what a live dictation run typed into the field, and the planner that brings it to
/// the app's target text (`LiveDictationSnapshot`). Pure: the keyboard feeds it the snapshot and the field's
/// text before the cursor, and carries out the `ShadowOp`s it returns.
///
/// - Lazy shadow: no walking and no full-field read. The *region* is the text Legato typed since the run began (or
///   since the last freeze) and ends at the cursor; the *anchor* is what the field held before it (seeded from
///   `documentContextBeforeInput`). Text after the cursor is never touched, so it is never read.
/// - Appends (the target only grows the region) go out a slice at a time through `TypewriterDrain`. Anything else
///   (a Soniox revision, a cleaned sentence, a changed head) is a word-level diff (`ShadowEditPlanner`) applied
///   at once, back to front, with the cursor returning to the end of the region.
/// - Drift: after our own edits the field's context must show anchor + region (`OwnEditEcho`). The host reports
///   it late (Safari's web process answers a batch of moves, deletes and inserts only when all of them ran, and the
///   report in between is the text before the cursor wherever it is on its way), so a mismatch is given
///   `echoLimitMs` to resolve. If it does not, or a selection appears, the user moved on: everything typed so far
///   is frozen, and the run goes on appending at the cursor once the field's report has stopped changing, so the
///   separator and capital are judged against the text that really is there.
/// - Frozen text is never edited again. Changes the target makes to a frozen sentence are dropped, except growth
///   of a sentence that was still being spoken: what follows the frozen part is appended at the cursor.
public struct RunShadow: Sendable, Equatable {
    /// `instruction`: an instruction's edit is about to change the text before the cursor.
    public enum FreezeCause: String, Sendable { case keystroke, cursor, selection, drift, field, instruction }

    public struct Step: Sendable, Equatable {
        public var ops: [ShadowOp] = []
        /// The region changed text it had already typed (a flip or a cleanup), not only grew.
        public var rewrote = false
        public var insertedChars = 0
        public var deletedChars = 0
        /// Set when this step froze the region (drift, or a selection).
        public var froze: FreezeCause?
        /// Why a drift was declared: lengths and character kinds only, never text.
        public var driftDetail: String?
        /// Set on the step that types the first characters of a region: what it was anchored to (lengths and kinds only).
        public var startDetail: String?
        /// The field's context does not echo the last edit yet: nothing was done, call again.
        public var waiting = false
        /// The field shows the whole target of `version` (and nothing was left to type).
        public var applied = false
        public var version: Int?
        /// More steps are needed: text is left to reveal, or the field has to catch up.
        public var needsTicks = false
    }

    public let runID: String
    /// What the field held before the region (context before the cursor when the region began).
    public private(set) var anchor = ""
    /// What Legato typed since, still editable; the cursor sits at its end.
    public private(set) var region = ""
    /// Ready to be seeded from the field at the next step (a new run, or right after a freeze).
    private var reseed = true
    private var waitedMs = 0.0
    /// Operations of the last batch: a longer batch takes the host longer to echo.
    private var lastOps = 0
    /// After a freeze: the field's report must hold still for `stableMs` before it seeds the new anchor.
    private var settling: Bool
    private var lastReport: String?
    private var stableForMs = 0.0
    private var frozen: [Int: Frozen] = [:]
    private var built = Built()
    /// The character after the cursor where the region began.
    private var following: Character?
    private static let closingMarks: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "\u{2019}", "\u{201D}"]

    /// `settlesFirst`: the run starts typing only once the field's report has held still for `stableMs`. Right after a
    /// tap or a focus the host can still report the text before the cursor as it was a moment ago (a missing trailing
    /// space would then be added again).
    public init(runID: String, settlesFirst: Bool = false) { self.runID = runID; settling = settlesFirst }

    /// What a sentence (by segment id) already has in the field and may not be edited any more.
    struct Frozen: Equatable, Sendable {
        var text: String
        /// The whole sentence was typed and it was final: nothing of it is typed again.
        var closed: Bool
    }
    /// The last target built: its text and where each segment sits in it.
    struct Built: Equatable, Sendable {
        struct Span: Equatable, Sendable {
            var id: Int
            var text: String
            var final: Bool
            var start: Int
            /// The span continues a frozen, half-typed word: no separator in front of it.
            var continuation: Bool
        }
        var spans: [Span] = []
        /// Characters of separator and the like the prepared text has before the spans' text.
        var prefix = 0
    }

    public var frozenSegments: Int { frozen.count }

    /// How long a field's report may disagree with the shadow before it counts as the user's edit.
    public static let echoBaseMs = 500.0
    public static let echoPerOpMs = 120.0
    public static let echoCapMs = 1500.0
    /// How long the report must stay unchanged after a freeze before the run types again.
    public static let stableMs = 150.0
    var echoLimitMs: Double { min(Self.echoCapMs, Self.echoBaseMs + Self.echoPerOpMs * Double(lastOps)) }

    // MARK: Step

    /// - Parameters:
    ///   - contextBefore: where the region would start now (the keyboard's tracked context, which includes its
    ///     own latest edit); used to seed the anchor and to place the first slice.
    ///   - reportedBefore: the field's own report, which lags behind edits; the drift check reads it.
    ///   - followingCharacter: the character right after the cursor (`documentContextAfterInput`), read only where
    ///     the run begins typing: text that follows without a space gets one from the run's first insert.
    public mutating func step(
        snapshot: LiveDictationSnapshot, contextBefore: String, reportedBefore: String, hasSelection: Bool,
        capitalization: AutoCapitalizationType, elapsedMs: Double, animated: Bool, followingCharacter: Character? = nil
    ) -> Step {
        var step = Step()
        if hasSelection {
            // Typing would replace the selection: the user took over.
            if freeze(.selection) { step.froze = .selection }
            step.needsTicks = true
            return step
        }
        if settling {
            if reportedBefore == lastReport { stableForMs += elapsedMs } else { lastReport = reportedBefore; stableForMs = 0 }
            if stableForMs < Self.stableMs { step.waiting = true; step.needsTicks = true; return step }
            settling = false
            anchor = reportedBefore; reseed = false; waitedMs = 0; following = followingCharacter
        } else if reseed || region.isEmpty { anchor = contextBefore; reseed = false; waitedMs = 0; following = followingCharacter }
        else if !OwnEditEcho.isSame(expected: anchor + region, reported: reportedBefore) {
            waitedMs += elapsedMs
            if waitedMs < echoLimitMs { step.waiting = true; step.needsTicks = true; return step }
            step.driftDetail = Self.describeMismatch(expected: anchor + region, reported: reportedBefore)
            // The report shows the text up to somewhere earlier in what was typed: the cursor moved, the text is as it was.
            let cause: FreezeCause = Self.cursorMoved(expected: anchor + region, reported: reportedBefore) ? .cursor : .drift
            _ = freeze(cause)
            step.froze = cause
            step.waiting = true; step.needsTicks = true
            return step
        } else {
            waitedMs = 0
        }

        let target = prepared(snapshot, capitalization: capitalization)
        // A target without any words never erases what is typed.
        if target == region || target.isEmpty {
            step.applied = true; step.version = snapshot.version
            return step
        }
        if target.hasPrefix(region) {
            let revealed = region.count, total = target.count
            let next = animated ? TypewriterDrain.step(revealed: revealed, target: total, dtMs: elapsedMs) : total
            let slice = String(target.dropFirst(revealed).prefix(next - revealed))
            if !slice.isEmpty {
                if region.isEmpty {
                    step.startDetail = "anchor=\(anchor.count) endsSpace=\(anchor.last?.isWhitespace == true ? 1 : 0) reported=\(reportedBefore.count) reportedEndsSpace=\(reportedBefore.last?.isWhitespace == true ? 1 : 0) following=\(following.map { $0.isWhitespace ? "space" : "char" } ?? "none") first=\(slice.first?.isWhitespace == true ? "space" : "char")"
                }
                if region.isEmpty, let next = following, !next.isWhitespace, !Self.closingMarks.contains(next) {
                    // The run starts in front of text that follows without a space: one goes in behind it, once, and the
                    // cursor stays in front of that space, so the run keeps typing where it is.
                    step.ops = [.insert(slice + " "), .move(-1)]; lastOps = 2
                } else {
                    step.ops = [.insert(slice)]; lastOps = 1
                }
                step.insertedChars = slice.count
                region += slice
            }
            if region == target { step.applied = true; step.version = snapshot.version } else { step.needsTicks = true }
            return step
        }
        let plan = ShadowEditPlanner.plan(shadow: region, cursor: region.utf16.count, target: target)
        for op in plan.ops {
            switch op {
            case .deleteBackward(let count): step.deletedChars += count
            case .insert(let text): step.insertedChars += text.count
            case .move: break
            }
        }
        step.ops = plan.ops; step.rewrote = true
        lastOps = plan.ops.count
        region = target
        step.applied = true; step.version = snapshot.version
        return step
    }

    /// The user took over (a key, a cursor move, another field): what is typed so far stays as it is. Returns
    /// whether anything was frozen. The next step seeds a new anchor at the cursor.
    @discardableResult
    public mutating func freeze(_ cause: FreezeCause) -> Bool {
        defer { reseed = true; region = ""; waitedMs = 0; built = Built(); settling = true; lastReport = nil; stableForMs = 0 }
        guard !region.isEmpty else { return false }
        let typed = max(0, region.count - built.prefix)
        for span in built.spans {
            let count = min(span.text.count, max(0, typed - span.start))
            guard count > 0 else { continue }
            let part = String(span.text.prefix(count))
            let known = frozen[span.id]
            let joined = known.map { $0.text + (span.continuation ? "" : " ") + part } ?? part
            frozen[span.id] = Frozen(text: joined, closed: count == span.text.count && span.final)
        }
        return true
    }

    /// What of a sentence still has to be typed after its frozen part. A frozen part that ends inside a word leaves that
    /// fragment where it is (the cursor is no longer there): the whole word is typed again with what follows. Words after
    /// the frozen part that the sentence changed under are matched by position.
    static func unfrozenRest(of text: String, frozen: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let typed = frozen.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = typed.last, !frozen.hasSuffix(" ") else {
            return text.hasPrefix(frozen) ? String(text.dropFirst(frozen.count)).trimmingCharacters(in: .whitespaces)
                                         : words.dropFirst(typed.count).joined(separator: " ")
        }
        // The frozen part ends in `last`: if the sentence's word there is longer, it was cut off; only its first
        // characters are in the field.
        guard typed.count <= words.count else { return "" }
        let word = words[typed.count - 1]
        var rest = Array(words.dropFirst(typed.count))
        if word.hasPrefix(last), word.count > last.count {
            let tail = word.dropFirst(last.count)
            // A word that goes on is typed whole; punctuation stuck to a finished word is not typed on its own.
            if let first = tail.first, first.isLetter || first.isNumber { rest.insert(word, at: 0) }
        }
        return rest.joined(separator: " ")
    }

    /// Whether the report is the shadow's text up to a point before its end, which is what the host reports when the
    /// cursor sits there: the user tapped into what was typed.
    static func cursorMoved(expected: String, reported: String) -> Bool {
        guard !reported.isEmpty, reported != expected, let range = expected.range(of: reported) else { return false }
        return range.upperBound < expected.endIndex
    }

    /// Where the field's report and the shadow part ways, without any text: both lengths, how many characters
    /// agree at the end, whether they agree once whitespace is normalised, and the kinds of the first characters that differ.
    static func describeMismatch(expected: String, reported: String) -> String {
        let e = Array(expected), r = Array(reported)
        var common = 0
        while common < min(e.count, r.count), e[e.count - 1 - common] == r[r.count - 1 - common] { common += 1 }
        func kind(_ chars: [Character], _ back: Int) -> String {
            guard back < chars.count else { return "none" }
            let c = chars[chars.count - 1 - back]
            if c == "\u{00A0}" { return "nbsp" }
            if c.isNewline { return "newline" }
            if c.isWhitespace { return "space" }
            if c.isLetter { return "letter" }
            if c.isNumber { return "digit" }
            return c.isASCII ? "punct" : "other"
        }
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // The report found inside the shadow, how many characters before its end: a lagging report is an older state.
        let found = expected.range(of: reported).map { expected.distance(from: $0.upperBound, to: expected.endIndex) } ?? -1
        let ne = normalized(expected), nr = normalized(reported)
        let alike = ne.hasSuffix(nr) || nr.hasSuffix(ne)
        return "e=\(e.count) r=\(r.count) common=\(common) wsOnly=\(alike ? 1 : 0) reportInShadowFromEnd=\(found) expectedKind=\(kind(e, common)) reportedKind=\(kind(r, common)) endsSpace=\(e.last?.isWhitespace == true ? 1 : 0)/\(r.last?.isWhitespace == true ? 1 : 0)"
    }

    // MARK: Target

    /// The text the region should hold for `snapshot`: its unfrozen sentences, separated from the anchor and
    /// capitalized where the text before the cursor calls for it.
    private mutating func prepared(_ snapshot: LiveDictationSnapshot, capitalization: AutoCapitalizationType) -> String {
        var raw = ""
        var spans: [Built.Span] = []
        var continuation = false
        for segment in snapshot.segments {
            var text = segment.text.trimmingCharacters(in: .whitespaces)
            var continues = false
            if let known = frozen[segment.id] {
                if known.closed { continue }
                text = Self.unfrozenRest(of: text, frozen: known.text)
            }
            guard !text.isEmpty else { continue }
            if raw.isEmpty { continuation = continues }
            else if let last = raw.last, !last.isWhitespace, let first = text.first, !first.isNewline, !continues { raw += " " }
            spans.append(.init(id: segment.id, text: text, final: segment.final, start: raw.count, continuation: continues))
            raw += text
        }
        guard !raw.isEmpty else { built = Built(spans: [], prefix: 0); return "" }
        let result = continuation ? raw : DictationTypist.prepare(raw, contextBefore: anchor, capitalization: capitalization)
        // `prepare` may put a separator in front (never changes the length otherwise).
        built = Built(spans: spans, prefix: result.count - raw.count)
        return result
    }
}
