import Foundation

/// Checks an instruction's scope against the field, then preserves the longest unchanged character subsequence.
/// Edits run back to front as single grapheme operations, returning the cursor to its logical place. On iOS the field
/// queue (`FieldQueue`) lands the edit; this plans and checks it, and builds an edit's undo.
public enum ScopedEditPlanner {
    public struct Plan: Sendable, Equatable {
        public var ops: [ShadowOp]
        /// Cursor after the ops, in UTF-16 units into the target.
        public var cursor: Int
        /// The field's text before the cursor once the ops ran, as far as the scope covers it.
        public var targetBefore: String
    }

    public enum Refusal: Error, Sendable, Equatable {
        /// The windows around the cursor no longer agree with the scope (the user typed, moved or switched fields).
        case changed
        /// The scope was a selection, and it is not selected any more.
        case selectionChanged
        case selectionNeedsCursor

        public var message: String {
            switch self {
            case .changed: "The text changed, so nothing was edited."
            case .selectionChanged: "The selection changed, so nothing was edited."
            case .selectionNeedsCursor: "This app did not confirm a cursor within the selection. Nothing was edited."
            }
        }
    }

    public static func plan(_ edit: ScopedEdit, windowBefore: String, windowAfter: String, selected: String?) -> Result<Plan, Refusal> {
        if let scope = edit.selected {
            guard selected == scope else { return .failure(.selectionChanged) }
            guard scope == edit.target else { return .failure(.selectionNeedsCursor) }
            return .success(Plan(ops: [], cursor: edit.target.utf16.count, targetBefore: edit.target))
        }
        guard selected?.isEmpty != false,
              agrees(scope: edit.before, window: windowBefore, atEnd: true),
              agrees(scope: edit.after, window: windowAfter, atEnd: false) else { return .failure(.changed) }
        let shadow = edit.before + edit.after
        let plan = ShadowEditPlanner.plan(shadow: shadow, cursor: edit.before.utf16.count,
                                          target: edit.target, characters: true)
        let before = String(decoding: Array(edit.target.utf16.prefix(plan.cursor)), as: UTF16.self)
        return .success(Plan(ops: plan.ops, cursor: plan.cursor, targetBefore: before))
    }

    /// A window (cut short by the host) and the scope agree where they overlap: next to the cursor. An empty window
    /// agrees only with an empty scope side: "nothing before the cursor" is not the end of any text.
    static func agrees(scope: String, window: String, atEnd: Bool) -> Bool {
        if scope.isEmpty { return true }
        if window.isEmpty { return false }
        if atEnd {
            // A block-based host's window may start with its boundary as "\n " (`FieldReader.trusted(before:)`).
            let trusted = FieldReader.trusted(before: window)
            return scope.hasSuffix(window) || window.hasSuffix(scope) || (!trusted.isEmpty && scope.hasSuffix(trusted))
        }
        return scope.hasPrefix(window) || window.hasPrefix(scope)
    }

    /// The undo of a landed edit: the text the edit produced (split where the cursor ended) goes back to what it replaced.
    public static func undo(of edit: ScopedEdit, cursor: Int, id: String = UUID().uuidString) -> ScopedEdit {
        let units = Array(edit.target.utf16)
        let split = min(max(0, cursor), units.count)
        return ScopedEdit(id: id, instructionID: edit.instructionID, documentID: edit.documentID,
                          before: String(decoding: units[..<split], as: UTF16.self),
                          after: String(decoding: units[split...], as: UTF16.self),
                          target: edit.scopeText)
    }
}

/// The text Legato typed in this keyboard appearance that still ends at the cursor: the instruction scope `session`.
/// Live runs extend it; an instruction's edit rewrites it; anything the user does at the cursor (a key, a move, a
/// selection, another field) ends it.
public struct SessionSpan: Sendable, Equatable {
    /// Ends at the cursor; empty when no session text is known.
    public private(set) var text = ""
    /// The text begins at the field's start (the first run started in an empty field).
    public private(set) var startsField = false
    /// What stood before the current run's region.
    private var base = ""
    private var region = ""
    private var runID: String?
    /// The next region continues the session (after an instruction's edit) instead of starting a new one.
    private var contiguous = false

    public init() {}

    /// A live run's region after a step: `anchor` is what the field held before it when it began.
    public mutating func track(runID: String, anchor: String, region: String) {
        if region.isEmpty { self.region = ""; return }
        if self.region.isEmpty || runID != self.runID {
            // A region begins: it continues the session only when nothing broke it since, and the field before it still
            // ends with the session text (the host may have changed the field without the keyboard, e.g. emptied it).
            let continues = contiguous && !text.isEmpty && OwnEditEcho.isSame(expected: text, reported: anchor)
            base = continues ? text : ""
            if !continues { startsField = anchor.isEmpty }
            contiguous = true
        }
        self.runID = runID; self.region = region
        text = base + region
    }

    /// The user took over at the cursor (a key, a move, a selection, another field): the session text is gone.
    public mutating func broken() { self = SessionSpan() }

    /// Legato edited the text before the cursor: the last `before.count` characters became `newBefore`. A region that
    /// was open is closed (the live run was frozen for the edit); the next region continues from the edited text.
    public mutating func edited(before: String, newBefore: String) {
        if before.count >= text.count {
            // The edit covered the whole session text: its result is Legato's text now.
            if before.count > text.count { startsField = false }
            text = newBefore
        } else {
            text = String(text.dropLast(before.count)) + newBefore
        }
        base = text; region = ""; contiguous = true
    }
}
