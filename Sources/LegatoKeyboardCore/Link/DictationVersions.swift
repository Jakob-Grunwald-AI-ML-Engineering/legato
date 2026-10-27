import Foundation

/// The versions of the last dictation that landed in the field: the raw text, the cleaned text (when
/// cleanup changed it) and any refinements, with the one the field shows now. The keyboard swaps between
/// them only while the field still ends with the shown version.
public struct DictationVersions: Sendable, Equatable {
    public let runID: String
    /// The field the dictation landed in.
    public let documentID: String
    /// Raw first, then cleaned, then refinements; trimmed and distinct.
    public private(set) var texts: [String]
    /// The index of the version in the field.
    public private(set) var current: Int
    /// Whitespace that follows the version in the field (what the engine left after the streamed text);
    /// it stays across swaps.
    public let trailing: String

    public init(runID: String, documentID: String, texts: [String], current: Int, trailing: String) {
        self.runID = runID
        self.documentID = documentID
        self.texts = texts
        self.current = current
        self.trailing = trailing
    }

    /// The versions once the run's final state landed (`cursor.finalApplied`); nil before that, for
    /// another run, for an empty run, or when the final text did not land (the field changed under it).
    public static func landed(state: HostState, cursor: AppliedCursor?) -> DictationVersions? {
        guard state.isFinal, let runID = state.runID, let cursor, cursor.runID == runID, cursor.finalApplied else {
            return nil
        }
        if state.delivery == .live, cursor.sentBase > 0 { return landedAfterSent(state: state, cursor: cursor, runID: runID) }
        let raw = state.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var texts = [raw]
        if let cleaned = ProxyEditPlanner.cleanedText(state) { texts.append(cleaned) }
        let streamedTrailing = ProxyEditPlanner.trailingWhitespace(of: ProxyEditPlanner.streamedSpan(of: state.committed))
        switch state.delivery {
        case .hold:
            return DictationVersions(
                runID: runID, documentID: cursor.documentID, texts: texts, current: texts.count - 1, trailing: "")
        case .clipboard:
            return DictationVersions(
                runID: runID, documentID: cursor.documentID, texts: texts, current: 0, trailing: streamedTrailing)
        case .live:
            // Landed means every revision did: the field shows the cleaned text.
            return DictationVersions(
                runID: runID, documentID: cursor.documentID, texts: texts, current: texts.count - 1,
                trailing: streamedTrailing)
        case .replace, nil:
            let current = cursor.finalReplaced == true ? texts.count - 1 : 0
            return DictationVersions(
                runID: runID, documentID: cursor.documentID, texts: texts, current: current, trailing: streamedTrailing)
        }
    }

    /// A live run that was sent (the field cleared) part of the way: the field holds only the text after the
    /// last boundary, so the versions cover that (raw, and what the field shows); nil when nothing followed.
    private static func landedAfterSent(state: HostState, cursor: AppliedCursor, runID: String) -> DictationVersions? {
        let raw = String(state.committed.dropFirst(cursor.sentBase)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let shown = ProxyEditPlanner.runText(cursor: cursor, committed: state.committed, upTo: state.committed.count)
        let cleaned = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        let texts = cleaned.isEmpty || cleaned == raw ? [raw] : [raw, cleaned]
        return DictationVersions(
            runID: runID, documentID: cursor.documentID, texts: texts, current: texts.count - 1,
            trailing: ProxyEditPlanner.trailingWhitespace(of: shown))
    }

    /// Exactly what the field ends with while it shows the current version.
    public var shown: String { texts[current] + trailing }
    public var hasPrevious: Bool { current > 0 }
    public var hasNext: Bool { current < texts.count - 1 }

    /// The edit that puts version `index` in place of the shown one: nil when there is no such version or
    /// the field no longer ends with the shown version (the user moved on), empty when it is shown already.
    public func swapOps(to index: Int, contextBefore: String) -> [ProxyOp]? {
        guard texts.indices.contains(index), contextBefore.hasSuffix(shown) else { return nil }
        guard index != current else { return [] }
        return ProxyEditPlanner.replaceOps(from: shown, to: texts[index] + trailing)
    }

    /// Records that the field now shows version `index` (after its `swapOps` ran).
    public mutating func show(_ index: Int) {
        guard texts.indices.contains(index) else { return }
        current = index
    }

    /// Adds a version (a refinement) at the end and returns its index; a text that is already a version is
    /// not added again (its index is returned).
    public mutating func add(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = texts.firstIndex(of: trimmed) { return existing }
        guard !trimmed.isEmpty else { return current }
        texts.append(trimmed)
        return texts.count - 1
    }
}
