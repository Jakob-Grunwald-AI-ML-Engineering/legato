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
/// - Drift: after our own edits the field's context must show anchor + region (`OwnEditEcho`, given
///   `TypewriterReveal.settleLimitMs` to catch up). If it does not, or a selection appears, the user moved on:
///   everything typed so far is frozen, and the run goes on appending at the cursor.
/// - Frozen text is never edited again. Changes the target makes to a frozen sentence are dropped, except growth
///   of a sentence that was still being spoken: what follows the frozen part is appended at the cursor.
public struct RunShadow: Sendable, Equatable {
    public enum FreezeCause: String, Sendable { case keystroke, cursor, selection, drift, field }

    public struct Step: Sendable, Equatable {
        public var ops: [ShadowOp] = []
        /// The region changed text it had already typed (a flip or a cleanup), not only grew.
        public var rewrote = false
        public var insertedChars = 0
        public var deletedChars = 0
        /// Set when this step froze the region (drift, or a selection).
        public var froze: FreezeCause?
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
    private var frozen: [Int: Frozen] = [:]
    private var built = Built()

    public init(runID: String) { self.runID = runID }

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

    // MARK: Step

    /// - Parameters:
    ///   - contextBefore: where the region would start now (the keyboard's tracked context, which includes its
    ///     own latest edit); used to seed the anchor and to place the first slice.
    ///   - reportedBefore: the field's own report, which lags behind edits; the drift check reads it.
    public mutating func step(
        snapshot: LiveDictationSnapshot, contextBefore: String, reportedBefore: String, hasSelection: Bool,
        capitalization: AutoCapitalizationType, elapsedMs: Double, animated: Bool
    ) -> Step {
        var step = Step()
        if hasSelection {
            // Typing would replace the selection: the user took over.
            if freeze(.selection) { step.froze = .selection }
            step.needsTicks = true
            return step
        }
        if reseed || region.isEmpty { anchor = contextBefore; reseed = false; waitedMs = 0 }
        else if !OwnEditEcho.isSame(expected: anchor + region, reported: reportedBefore) {
            waitedMs += elapsedMs
            if waitedMs < TypewriterReveal.settleLimitMs { step.waiting = true; step.needsTicks = true; return step }
            _ = freeze(.drift)
            step.froze = .drift
            anchor = contextBefore; reseed = false
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
                step.ops = [.insert(slice)]; step.insertedChars = slice.count
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
        region = target
        step.applied = true; step.version = snapshot.version
        return step
    }

    /// The user took over (a key, a cursor move, another field): what is typed so far stays as it is. Returns
    /// whether anything was frozen. The next step seeds a new anchor at the cursor.
    @discardableResult
    public mutating func freeze(_ cause: FreezeCause) -> Bool {
        defer { reseed = true; region = ""; waitedMs = 0; built = Built() }
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
                if text.hasPrefix(known.text) {
                    let rest = String(text.dropFirst(known.text.count))
                    continues = !rest.isEmpty && !known.text.hasSuffix(" ") && !(rest.first?.isWhitespace ?? true)
                    text = rest.trimmingCharacters(in: .whitespaces)
                } else {
                    // The words moved under the frozen part: only the words after the ones already typed are new.
                    let words = text.split(whereSeparator: \.isWhitespace)
                    let typedWords = known.text.split(whereSeparator: \.isWhitespace).count
                    text = words.dropFirst(typedWords).joined(separator: " ")
                }
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
