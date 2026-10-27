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
    /// A recheck is due for a field that showed the run's text: type nothing of the run until then.
    public private(set) var holds = false

    public init() {}

    /// The keyboard edited the field itself (typed, deleted, applied the host's text).
    public mutating func ownEdit(at now: Date) {
        lastOwnEditAt = now
    }

    /// The keyboard typed a Return (after its own edits for it): an empty field after it is believed at once.
    public mutating func returnTyped(at now: Date) {
        lastOwnEditAt = nil
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
