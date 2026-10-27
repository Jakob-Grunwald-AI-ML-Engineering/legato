import Foundation

/// The keyboard's own edits, for undo and redo. Pure: it never touches the field. `undo` and `redo` return
/// what to apply; the caller applies it through the same path as any keyboard edit.
///
/// Typing is grouped by word: a space or punctuation (included in the group), a cursor move or
/// `idleGap` of silence closes the group. Dictation, cleanup and Refine results are `.version` entries
/// that undo through the dictation's versions, guarded by the caller. Every other entry is guarded: the
/// text before the cursor must still end with what the entry inserted (redo: removed), else the field
/// changed behind the keyboard's back and the history is cleared.
public struct EditHistory: Sendable, Equatable {
    public static let capacity = 50
    /// Typing pauses longer than this start a new entry.
    public static let idleGap: TimeInterval = 1.5

    public enum Kind: Sendable, Equatable {
        case text
        /// A dictation version swap: undo shows `from`, redo shows `to`.
        case version(from: Int, to: Int)
    }

    public struct Entry: Sendable, Equatable {
        public var removed: String
        public var inserted: String
        public var kind: Kind

        public init(removed: String, inserted: String, kind: Kind) {
            self.removed = removed
            self.inserted = inserted
            self.kind = kind
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

    /// Typed text (a keystroke or a pasted run).
    public mutating func typed(_ text: String, at now: Date) {
        guard !text.isEmpty else { return }
        if groupOpen, let last = lastTypedAt, now.timeIntervalSince(last) > Self.idleGap { closeGroup() }
        redoEntries = []
        if groupOpen, let index = entries.indices.last {
            entries[index].inserted += text
        } else {
            append(Entry(removed: "", inserted: text, kind: .text))
            groupOpen = true
        }
        lastTypedAt = now
        if text.contains(where: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol }) { closeGroup() }
    }

    /// Text removed by a backspace. It shortens the open typing group; otherwise it is an entry of its own.
    public mutating func deleted(_ text: String, at now: Date) {
        guard !text.isEmpty else { return }
        if groupOpen, let index = entries.indices.last, entries[index].inserted.hasSuffix(text) {
            entries[index].inserted.removeLast(text.count)
            if entries[index].inserted.isEmpty && entries[index].removed.isEmpty {
                entries.removeLast()
                closeGroup()
            }
            lastTypedAt = now
            return
        }
        record(removed: text, inserted: "", at: now)
    }

    /// A discrete edit (a completion, a word swap, a cleanup replacement).
    public mutating func record(removed: String, inserted: String, at now: Date) {
        closeGroup()
        redoEntries = []
        append(Entry(removed: removed, inserted: inserted, kind: .text))
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
            guard contextBefore.hasSuffix(entry.inserted) else { clear(); return nil }
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
            guard contextBefore.hasSuffix(entry.removed) else { clear(); return nil }
            redoEntries.removeLast()
            entries.append(entry)
            return .edit(WordEdit(forward: 0, deleteCount: entry.removed.count, insert: entry.inserted))
        }
    }

    // MARK: Internals

    private mutating func closeGroup() {
        groupOpen = false
        lastTypedAt = nil
    }

    private mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }
}
