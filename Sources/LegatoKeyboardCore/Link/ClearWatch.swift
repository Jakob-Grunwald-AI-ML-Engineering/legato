import Foundation

/// Decides when the keyboard believes its field was emptied by the host (a chat app's Send) and what that
/// means for the run (`ProxyEditPlanner.fieldCleared`).
///
/// - Right after the keyboard's own edit the field's reported context can lag it, so an empty field then is
///   not believed at once: it is looked at again when `ownEditWindowMs` has passed since that edit (`recheck`),
///   and a real clear is never lost. While such a recheck is due for a field that showed the run's text
///   (`holds`), the keyboard types nothing of the run, so the recheck finds the field as the host left it.
/// - A Return the keyboard typed holds nothing back: it is the most likely send (a chat app sends on Return
///   and empties the field), so an empty field right after it is believed at once.
public struct ClearWatch: Sendable, Equatable {
    /// How long after the keyboard's own edit the field's reported context may still lag it.
    public static let ownEditWindowMs = TypewriterReveal.settleLimitMs

    public enum Outcome: Sendable, Equatable {
        /// The field has text: no clear.
        case notCleared
        /// The field looks empty right after the keyboard's own edit: look again at `at`.
        case recheck(at: Date)
        /// The field was emptied; `sent` is the run's cursor with a sent boundary when it showed the run's text.
        case cleared(sent: AppliedCursor?)
    }

    private var lastOwnEditAt: Date?
    private var lastOwnEditLeftEmpty = false
    /// A recheck is due for a field that showed the run's text: type nothing of the run until then.
    public private(set) var holds = false

    public init() {}

    /// Whether a cleared field is the host's doing. False when the keyboard's own last edit left the field empty
    /// (undo of the first word, holding delete, undoing a dictation): the keyboard's history is then still good.
    public var hostEmptiedField: Bool { !lastOwnEditLeftEmpty }

    /// The keyboard edited the field itself (typed, deleted, applied the host's text). `leavesFieldEmpty`: the
    /// edit leaves no text in the field.
    public mutating func ownEdit(at now: Date, leavesFieldEmpty: Bool = false) {
        lastOwnEditAt = now
        lastOwnEditLeftEmpty = leavesFieldEmpty
    }

    /// The keyboard typed a Return (after its own edits for it): an empty field after it is believed at once.
    public mutating func returnTyped(at now: Date) {
        lastOwnEditAt = nil
        lastOwnEditLeftEmpty = false
    }

    /// The user is about to press a key (typed, delete, Return, a suggestion): a clear held back for its recheck
    /// is resolved now, against the field as it is before the key, so the key cannot hide it. Nothing held, or a
    /// field with text again: `.notCleared`.
    public mutating func resolveHeld(
        state: HostState?, cursor: AppliedCursor?, documentID: String?, contextBefore: String, hasText: Bool
    ) -> Outcome {
        guard holds else { return .notCleared }
        lastOwnEditAt = nil // the window is for the field's lag after an edit; the key has not edited anything yet
        return check(
            state: state, cursor: cursor, documentID: documentID, contextBefore: contextBefore, hasText: hasText,
            now: Date())
    }

    /// Looks at the field as it is now: on the field's change, before each edit of the run, and at a recheck.
    public mutating func check(
        state: HostState?, cursor: AppliedCursor?, documentID: String?, contextBefore: String, hasText: Bool, now: Date
    ) -> Outcome {
        guard !hasText, contextBefore.allSatisfy(\.isWhitespace) else {
            holds = false
            return .notCleared
        }
        let sent = state.flatMap {
            ProxyEditPlanner.fieldCleared(
                state: $0, cursor: cursor, documentID: documentID, contextBefore: contextBefore, hasText: false)
        }
        if let last = lastOwnEditAt, now.timeIntervalSince(last) * 1000 < Self.ownEditWindowMs {
            holds = sent != nil
            return .recheck(at: last.addingTimeInterval(Self.ownEditWindowMs / 1000))
        }
        holds = false
        return .cleared(sent: sent)
    }
}
