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
        current.finalApplied = state.isFinal && current.committedCount == state.committed.count && current.volatile.isEmpty
        return ProxyPlan(ops: ops, cursor: current)
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
