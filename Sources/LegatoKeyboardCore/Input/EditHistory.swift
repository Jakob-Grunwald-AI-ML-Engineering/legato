import Foundation

/// The keyboard's own edits, for undo and redo. Pure: it never touches the field. `undo` and `redo` return
/// what to apply; the caller applies it through the same path as any keyboard edit.
///
/// Typing is grouped by word: a space or punctuation (included in the group), a cursor move or
/// `idleGap` of silence closes the group. Dictation, cleanup and Refine results are `.version` entries
/// that undo through the dictation's versions, guarded by the caller. Every other entry is guarded: the
/// text before the cursor must still end with what the entry inserted (redo: removed) and, when the
/// recording knew it, with the tail of the context the edit left (its anchor: where the cursor was), else
/// the field changed behind the keyboard's back and the history is cleared.
///
/// A run of backspaces (a held delete) is one entry, like a typing group: it ends with `idleGap` of silence,
/// or with anything that is not a backspace.
public struct EditHistory: Sendable, Equatable {
    public static let capacity = 50
    /// Typing pauses longer than this start a new entry.
    public static let idleGap: TimeInterval = 1.5
    /// How much of the context before the cursor an entry's anchor compares (the host may trim the rest).
    static let anchorLength = 24

    public enum Kind: Sendable, Equatable {
        case text
        /// A dictation version swap: undo shows `from`, redo shows `to`.
        case version(from: Int, to: Int)
    }

    public struct Entry: Sendable, Equatable {
        public var removed: String
        public var inserted: String
        public var kind: Kind
        /// The text before the cursor right after the edit, when it was known.
        public var anchor: String?

        public init(removed: String, inserted: String, kind: Kind, anchor: String? = nil) {
            self.removed = removed
            self.inserted = inserted
            self.kind = kind
            self.anchor = anchor
        }
    }

    /// What to do for an undo or redo.
    public enum Step: Sendable, Equatable {
        /// Apply this edit at the cursor.
        case edit(WordEdit)
        /// Show this dictation version (`versions.show`).
        case version(Int)
    }

    public private(set) var entries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var groupOpen = false
    /// The newest entry is a run of backspaces that further backspaces extend.
    private var deleteGroupOpen = false
    private var lastTypedAt: Date?

    public init() {}

    public var canUndo: Bool { !entries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }

    public mutating func clear() {
        entries = []
        redoEntries = []
        closeGroup()
    }

    /// The cursor moved by other means than typing.
    public mutating func cursorMoved() { closeGroup() }

    // MARK: Recording

    /// Typed text (a keystroke or a pasted run). `contextBefore`: the text before the cursor now, when known.
    public mutating func typed(_ text: String, at now: Date, contextBefore: String? = nil) {
        guard !text.isEmpty else { return }
        if deleteGroupOpen { closeGroup() }
        if groupOpen, let last = lastTypedAt, now.timeIntervalSince(last) > Self.idleGap { closeGroup() }
        redoEntries = []
        if groupOpen, let index = entries.indices.last {
            entries[index].inserted += text
            entries[index].anchor = contextBefore
        } else {
            append(Entry(removed: "", inserted: text, kind: .text, anchor: contextBefore))
            groupOpen = true
        }
        lastTypedAt = now
        if text.contains(where: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol }) { closeGroup() }
    }

    /// Text removed by a backspace. It shortens the open typing group; otherwise it joins the run of backspaces
    /// before it, or is an entry of its own. `contextBefore`: the text before the cursor now, when known.
    public mutating func deleted(_ text: String, at now: Date, contextBefore: String? = nil) {
        guard !text.isEmpty else { return }
        if groupOpen, let index = entries.indices.last, entries[index].inserted.hasSuffix(text) {
            entries[index].inserted.removeLast(text.count)
            entries[index].anchor = contextBefore
            if entries[index].inserted.isEmpty && entries[index].removed.isEmpty {
                entries.removeLast()
                closeGroup()
            }
            lastTypedAt = now
            return
        }
        if deleteGroupOpen, let last = lastTypedAt, now.timeIntervalSince(last) <= Self.idleGap, let index = entries.indices.last,
           entries[index].inserted.isEmpty, case .text = entries[index].kind {
            entries[index].removed = text + entries[index].removed
            entries[index].anchor = contextBefore
            lastTypedAt = now
            return
        }
        record(removed: text, inserted: "", at: now, contextBefore: contextBefore)
        deleteGroupOpen = true
        lastTypedAt = now
    }

    /// A discrete edit (a completion, a word swap, a cleanup replacement).
    public mutating func record(removed: String, inserted: String, at now: Date, contextBefore: String? = nil) {
        closeGroup()
        redoEntries = []
        append(Entry(removed: removed, inserted: inserted, kind: .text, anchor: contextBefore))
    }

    /// A dictation, cleanup or Refine result: the field went from version `from` to version `to`.
    public mutating func recordVersion(from: Int, to: Int, at now: Date) {
        closeGroup()
        redoEntries = []
        append(Entry(removed: "", inserted: "", kind: .version(from: from, to: to)))
    }

    // MARK: Undo and redo

    /// The step that undoes the newest entry, or nil when there is none or the guard failed (history cleared).
    public mutating func undo(contextBefore: String) -> Step? {
        closeGroup()
        guard let entry = entries.last else { return nil }
        switch entry.kind {
        case .version(let from, _):
            entries.removeLast()
            redoEntries.append(entry)
            return .version(from)
        case .text:
            guard contextBefore.hasSuffix(entry.inserted), Self.anchored(contextBefore, at: entry.anchor) else { clear(); return nil }
            entries.removeLast()
            redoEntries.append(entry)
            return .edit(WordEdit(forward: 0, deleteCount: entry.inserted.count, insert: entry.removed))
        }
    }

    /// The step that redoes the newest undone entry, or nil when there is none or the guard failed.
    public mutating func redo(contextBefore: String) -> Step? {
        closeGroup()
        guard let entry = redoEntries.last else { return nil }
        switch entry.kind {
        case .version(_, let to):
            redoEntries.removeLast()
            entries.append(entry)
            return .version(to)
        case .text:
            guard contextBefore.hasSuffix(entry.removed),
                  Self.anchored(contextBefore, at: entry.anchor.map { String($0.dropLast(entry.inserted.count)) + entry.removed })
            else { clear(); return nil }
            redoEntries.removeLast()
            entries.append(entry)
            return .edit(WordEdit(forward: 0, deleteCount: entry.removed.count, insert: entry.inserted))
        }
    }

    /// An undo step that could not be carried out (the dictation version could not be shown): the entry is back.
    public mutating func revertUndo() {
        guard let entry = redoEntries.popLast() else { return }
        entries.append(entry)
    }

    /// A redo step that could not be carried out: the entry is back on the redo stack.
    public mutating func revertRedo() {
        guard let entry = entries.popLast() else { return }
        redoEntries.append(entry)
    }

    // MARK: Internals

    /// Whether the cursor still sits where the edit left it: the text before it ends with the tail of the
    /// edit's anchor. No anchor, no check.
    private static func anchored(_ contextBefore: String, at anchor: String?) -> Bool {
        guard let anchor else { return true }
        if contextBefore.hasSuffix(String(anchor.suffix(anchorLength))) { return true }
        // A host that trims its context shorter than the tail: what it reports must be the anchor's end.
        return !contextBefore.isEmpty && anchor.hasSuffix(contextBefore)
    }

    private mutating func closeGroup() {
        groupOpen = false
        deleteGroupOpen = false
        lastTypedAt = nil
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}
