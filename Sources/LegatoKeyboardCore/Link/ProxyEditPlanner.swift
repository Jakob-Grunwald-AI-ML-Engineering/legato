import Foundation

public enum ProxyOp: Sendable, Equatable {
    /// Delete this many characters before the insertion point (one `deleteBackward()` each).
    case deleteBackward(Int)
    case insert(String)
}

public struct ProxyPlan: Sendable, Equatable {
    public var ops: [ProxyOp]
    /// The cursor after the ops ran; persist it as `link.applied`.
    public var cursor: AppliedCursor?

    public init(ops: [ProxyOp], cursor: AppliedCursor?) {
        self.ops = ops
        self.cursor = cursor
    }
}

/// Turns the host's state into the edits that bring the keyboard's text field in line with it, from
/// where the field is now: what `cursor` says was typed already and what `contextBefore`
/// (`documentContextBeforeInput`) shows is there.
///
/// - Committed text is only ever appended: the part of `committed` past `cursor.committedCount`.
/// - The volatile tail is revised by a common-prefix diff against what is in the field, and is deleted
///   only while the context still ends with it; otherwise it is left alone (it has become the user's).
/// - Edits go only to the document the run is bound to; a run binds to the document it first types into.
///   With no document (`documentID` nil: no field is bound) nothing is planned and the cursor stays.
/// - A separating space goes in front of the first text of a run (and after the user typed into the
///   run) when the field's text before it doesn't end in whitespace.
/// - Cleanup (`HostState.delivery`, `finalText`): with `.replace` the streamed text is swapped for the
///   final text in one edit once it has all landed, only while the field still ends with it (never
///   retried; without the swap the final state is not confirmed, so the app uses the clipboard). With
///   `.clipboard` the streamed text stays. With `.hold` nothing is typed while listening; the final text
///   is inserted once, at the end.
/// - Live cleanup (`.live`): the newest `HostState.revision` replaces what the field shows for the run
///   (`runText`) with its text followed by the raw text committed after it, in one common-prefix edit, when
///   the field still ends with exactly that run text (`applyLiveRevision`). One that would replace text not
///   typed yet waits. When the field no longer ends with it (the user edited) the revision is skipped, and
///   so is every later one. The final state is confirmed only when the newest revision landed and none was
///   skipped. A cleared field is a sent boundary (`fieldCleared`): revisions of the sent text are dropped and
///   the rest of the run streams into the empty field.
public enum ProxyEditPlanner {
    public static func plan(
        state: HostState, cursor: AppliedCursor?, contextBefore: String, documentID: String?
    ) -> ProxyPlan {
        guard let documentID, state.target == .keyboard, let runID = state.runID else { return ProxyPlan(ops: [], cursor: cursor) }

        var ops: [ProxyOp] = []
        var context = contextBefore
        var current: AppliedCursor
        if let cursor, cursor.runID == runID {
            guard cursor.documentID == documentID else { return ProxyPlan(ops: [], cursor: cursor) }
            current = cursor
        } else {
            // A new run. Tentative text the previous run left in this field goes, if it is still the last thing there.
            if let old = cursor, old.documentID == documentID, !old.volatile.isEmpty, context.hasSuffix(old.volatile) {
                ops.append(.deleteBackward(old.volatile.count))
                context.removeLast(old.volatile.count)
            }
            current = AppliedCursor(runID: runID, documentID: documentID)
        }

        if state.delivery == .hold { return planHeld(state: state, cursor: current, ops: ops, context: context) }
        if state.delivery == .live { return planLive(state: state, cursor: current, ops: ops, context: context) }

        // The tentative text in the field is only editable while it is still the end of the context.
        var inField = current.volatile
        if !inField.isEmpty {
            if context.hasSuffix(inField) { context.removeLast(inField.count) } else { inField = "" }
        }

        let delta = state.committed.count > current.committedCount
            ? String(state.committed.dropFirst(current.committedCount)) : ""
        let body = delta + state.volatile
        let separator = (current.committedCount == 0 || current.needsSeparator) && needsSeparator(before: context, inserting: body)
            ? " " : ""
        let target = separator + body

        let shared = commonPrefixCount(inField, target)
        if inField.count > shared { ops.append(.deleteBackward(inField.count - shared)) }
        let missing = String(target.dropFirst(shared))
        if !missing.isEmpty { ops.append(.insert(missing)) }

        current.committedCount += delta.count
        // With nothing newly committed the separator belongs to the tentative text; otherwise it is committed.
        current.volatile = delta.isEmpty ? separator + state.volatile : state.volatile
        current.needsSeparator = current.needsSeparator && delta.isEmpty
        let streamedLanded = state.isFinal && current.committedCount == state.committed.count && current.volatile.isEmpty
        current.finalApplied = streamedLanded
        if streamedLanded, state.delivery != .clipboard, let finalText = cleanedText(state) {
            if current.finalReplaced == nil {
                let span = streamedSpan(of: state.committed)
                if !span.isEmpty, (context + target).hasSuffix(span) {
                    ops += replaceOps(from: span, to: finalText + trailingWhitespace(of: span))
                    current.finalReplaced = true
                } else {
                    current.finalReplaced = false
                }
            }
            current.finalApplied = current.finalReplaced == true
        }
        return ProxyPlan(ops: ops, cursor: current)
    }

    /// `.live`: streams like `.replace` and applies the new revisions; the edit is one common-prefix diff
    /// from the field as it is to the field as it should be.
    private static func planLive(state: HostState, cursor: AppliedCursor, ops: [ProxyOp], context: String) -> ProxyPlan {
        var ops = ops
        var current = cursor
        var stripped = context
        var inField = current.volatile
        if !inField.isEmpty {
            if stripped.hasSuffix(inField) { stripped.removeLast(inField.count) } else { inField = "" }
        }
        let delta = state.committed.count > current.committedCount
            ? String(state.committed.dropFirst(current.committedCount)) : ""
        let body = delta + state.volatile
        let separator = (current.committedCount == 0 || current.needsSeparator) && needsSeparator(before: stripped, inserting: body)
            ? " " : ""

        // The field's committed part once this plan ran, before the tentative text.
        let committedCount = current.committedCount + delta.count
        var field = stripped + (delta.isEmpty ? "" : separator + delta)
        applyLiveRevision(state: state, cursor: &current, committedCount: committedCount, field: &field)
        let desired = field + (delta.isEmpty ? separator : "") + state.volatile
        // The field holds `context`; the edit turns it into `desired` (a shared beginning stays).
        ops += replaceOps(from: context, to: desired)

        current.committedCount = committedCount
        current.volatile = delta.isEmpty ? separator + state.volatile : state.volatile
        current.needsSeparator = current.needsSeparator && delta.isEmpty
        let streamedLanded = state.isFinal && committedCount == state.committed.count && current.volatile.isEmpty
        current.finalApplied = streamedLanded && current.revisionHandled >= (state.revision?.n ?? 0)
            && !current.revisionSkipped
        return ProxyPlan(ops: ops, cursor: current)
    }

    /// What the field shows for the run's committed text since the last sent boundary, up to `count` raw
    /// characters typed: the applied revision's text, then the raw text after it.
    static func runText(cursor: AppliedCursor, committed: String, upTo count: Int) -> String {
        let from = max(cursor.revisedEnd, cursor.sentBase)
        guard count > from else { return count == from ? cursor.revisedText : "" }
        return cursor.revisedText + String(committed.dropFirst(from).prefix(count - from))
    }

    /// Applies `state.revision` to `field` (the field's text up to the end of the run's committed part,
    /// `committedCount` raw characters typed) when it is newer than the one the cursor handled: replaces the
    /// run text the field ends with by the revision's text and the raw text after it. A revision past the
    /// typed text waits; one of text before the last sent boundary is dropped; after a skip, or when the field
    /// no longer ends with the run text, it is skipped. Kept apart from the planning so a typewriter reveal can
    /// drive the same replacement.
    static func applyLiveRevision(state: HostState, cursor: inout AppliedCursor, committedCount: Int, field: inout String) {
        guard let revision = state.revision, revision.n > cursor.revisionHandled else { return }
        guard revision.start == cursor.sentBase, !cursor.revisionSkipped else {
            cursor.revisionHandled = revision.n // the sent text's, or the user's field: never applied
            return
        }
        guard revision.end <= committedCount, committedCount <= state.committed.count else { return } // waits
        let shown = runText(cursor: cursor, committed: state.committed, upTo: committedCount)
        let rawMatches = String(state.committed.dropFirst(revision.start).prefix(revision.raw.count)) == revision.raw
        if rawMatches, field.hasSuffix(shown) {
            field = String(field.dropLast(shown.count)) + revision.text
                + String(state.committed.dropFirst(revision.end).prefix(committedCount - revision.end))
            cursor.revisedEnd = revision.end
            cursor.revisedText = revision.text
            cursor.shownRevision = revision.n
        } else if rawMatches {
            cursor.revisionSkipped = true
        }
        cursor.revisionHandled = revision.n
    }

    /// The keyboard saw its field change (the host's own edit): when the field is now empty although it showed
    /// the run's text (a chat app sent it), returns the cursor with a sent boundary at what was typed; nil for
    /// anything else (no run text there, another field, a finished run, an edit that left text). Only a `.live`
    /// run that is still going has boundaries. The field then shows nothing of the run: the rest streams into
    /// it afresh, without a separator, and revisions start over after the boundary.
    public static func fieldCleared(
        state: HostState, cursor: AppliedCursor?, documentID: String?, contextBefore: String, hasText: Bool
    ) -> AppliedCursor? {
        guard state.delivery == .live, state.target == .keyboard, !state.isFinal, let runID = state.runID,
              var current = cursor, current.runID == runID, current.documentID == documentID,
              !hasText, contextBefore.allSatisfy(\.isWhitespace)
        else { return nil }
        let shown = runText(cursor: current, committed: state.committed, upTo: current.committedCount) + current.volatile
        guard !shown.allSatisfy(\.isWhitespace) else { return nil }
        current.sentShownRevision = current.revisedEnd > current.sentBase ? current.shownRevision : 0
        current.sentBase = current.committedCount
        current.revisedEnd = current.committedCount
        current.revisedText = ""
        current.shownRevision = 0
        current.volatile = ""
        current.needsSeparator = false
        current.revisionSkipped = false
        current.finalApplied = false
        return current
    }

    /// `.hold`: nothing goes into the field while listening; the final text goes in once, at the end.
    private static func planHeld(state: HostState, cursor: AppliedCursor, ops: [ProxyOp], context: String) -> ProxyPlan {
        var ops = ops
        var current = cursor
        guard state.isFinal, !current.finalApplied else { return ProxyPlan(ops: ops, cursor: current) }
        let text = cleanedText(state) ?? state.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            ops.append(.insert((needsSeparator(before: context, inserting: text) ? " " : "") + text))
        }
        current.committedCount = state.committed.count
        current.volatile = ""
        current.finalApplied = true
        return ProxyPlan(ops: ops, cursor: current)
    }

    /// The final state's post-processed text, trimmed, when there is one that differs from the streamed text.
    static func cleanedText(_ state: HostState) -> String? {
        guard let text = state.finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text != state.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return text
    }

    /// What a run's streamed text left in the field: the committed text without its leading whitespace
    /// (that stays as the separator), trailing whitespace included.
    static func streamedSpan(of committed: String) -> String {
        String(committed.drop(while: \.isWhitespace))
    }

    static func trailingWhitespace(of text: String) -> String {
        String(text.reversed().prefix(while: \.isWhitespace).reversed())
    }

    /// The edit that turns `old`, the end of the field, into `new`: a shared beginning stays.
    static func replaceOps(from old: String, to new: String) -> [ProxyOp] {
        let shared = commonPrefixCount(old, new)
        var ops: [ProxyOp] = []
        if old.count > shared { ops.append(.deleteBackward(old.count - shared)) }
        let missing = String(new.dropFirst(shared))
        if !missing.isEmpty { ops.append(.insert(missing)) }
        return ops
    }

    /// The user is about to type into the field mid-run: remove the tentative text (if it is still the end
    /// of the context) so the key lands after the committed text. The next `plan` brings the tentative
    /// text back after the key, separated by a space.
    public static func prepareForTyping(cursor: AppliedCursor?, contextBefore: String) -> ProxyPlan {
        guard var current = cursor else { return ProxyPlan(ops: [], cursor: nil) }
        var ops: [ProxyOp] = []
        if !current.volatile.isEmpty, contextBefore.hasSuffix(current.volatile) {
            ops.append(.deleteBackward(current.volatile.count))
        }
        current.volatile = ""
        current.needsSeparator = true
        current.finalApplied = false
        return ProxyPlan(ops: ops, cursor: current)
    }

    // MARK: Pieces

    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "„", "“", "‘", "¿", "¡", "/", "-", "–", "—", "@", "#"]
    private static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "%", "”", "’", "/", "-"]

    private static func needsSeparator(before context: String, inserting text: String) -> Bool {
        guard let last = context.last, let first = text.first else { return false }
        return !last.isWhitespace && !first.isWhitespace && !noSpaceAfter.contains(last) && !noSpaceBefore.contains(first)
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
    }
}
