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
/// - Cleanup (`HostState.delivery`, `finalText`): with `.replace` the streamed text can be swapped for the
///   final text in one edit once it has all landed, only while the field still ends with it (never
///   retried; without the swap the final state is not confirmed, so the app uses the clipboard). A run on the
///   link (the app's cleanup agent) gets its cleaned text as patches instead and has no `finalText` here.
/// - A cleared field is a sent boundary (`fieldCleared`, `.live` runs): the rest of the run streams into the
///   empty field; tentative text it showed went too, and the committed text that finalizes it is not typed
///   again (`awaitsSentTentative`).
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

        // Tentative text sent with a message: nothing goes in until the committed text shows where it ends.
        if awaitsSentTentative(state: state, cursor: &current) { return ProxyPlan(ops: ops, cursor: current) }

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
        if streamedLanded, state.delivery != .live, let finalText = cleanedText(state) {
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

    /// `.live`: the field was cleared while it showed tentative text (`AppliedCursor.sentTentative`). Once the
    /// committed text after the boundary shows where that text ends (`SentTentative`; at the run's final state at
    /// the latest), the boundary moves past it and false is returned; true while that can't be told yet, and
    /// nothing of the run may be typed. Called with the host's whole state (not a reveal's cut of it).
    static func awaitsSentTentative(state: HostState, cursor: inout AppliedCursor) -> Bool {
        guard !cursor.sentTentative.isEmpty, state.runID == cursor.runID else { return false }
        let after = String(state.committed.dropFirst(cursor.sentBase))
        guard let covered = SentTentative.coveredCount(of: cursor.sentTentative, in: after, complete: state.isFinal)
        else { return true }
        cursor.sentBase += covered
        cursor.committedCount = max(cursor.committedCount, cursor.sentBase)
        cursor.sentTentative = ""
        return false
    }

    /// What the field shows for the run's committed text since the last sent boundary, up to `count` raw
    /// characters typed.
    static func runText(cursor: AppliedCursor, committed: String, upTo count: Int) -> String {
        guard count > cursor.sentBase else { return "" }
        return String(committed.dropFirst(cursor.sentBase).prefix(count - cursor.sentBase))
    }

    /// The keyboard saw its field change (the host's own edit): when the field is now empty although it showed
    /// the run's text (a chat app sent it), returns the cursor with a sent boundary at what was typed; nil for
    /// anything else (no run text there, another field, a run all in the field, an edit that left text). Only a
    /// `.live` run that is still going, or whose final state is still being typed, has boundaries. Everything
    /// the field showed went: the committed text up to the boundary and the tentative text after it
    /// (`sentTentative`, which the boundary moves past once it is committed: `awaitsSentTentative`). The field
    /// then shows nothing of the run: the rest streams into it afresh, without a separator.
    public static func fieldCleared(
        state: HostState, cursor: AppliedCursor?, documentID: String?, contextBefore: String, hasText: Bool
    ) -> AppliedCursor? {
        guard state.delivery == .live, state.target == .keyboard, let runID = state.runID,
              var current = cursor, current.runID == runID, current.documentID == documentID,
              !state.isFinal || !current.finalApplied, // the final state still being typed is a run going on
              !hasText, contextBefore.allSatisfy(\.isWhitespace)
        else { return nil }
        let shown = runText(cursor: current, committed: state.committed, upTo: current.committedCount) + current.volatile
        guard !shown.allSatisfy(\.isWhitespace) else { return nil }
        current.sentBase = current.committedCount
        current.sentTentative = current.volatile.allSatisfy(\.isWhitespace) ? "" : current.volatile
        current.sentCount += 1
        current.volatile = ""
        current.needsSeparator = false
        current.finalApplied = false
        return current
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
