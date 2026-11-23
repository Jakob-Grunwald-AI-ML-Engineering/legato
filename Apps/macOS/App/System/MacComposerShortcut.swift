import Carbon.HIToolbox
import LegatoMac
import LegatoAppServices

/// Composer-specific key bindings apply while the activity owns keyboard input.
enum MacComposerShortcut: Hashable, Sendable {
    case magic, insert, discard

    /// Magic shares its binding with the speech gesture. Undo Discard is in Legato's menu.
    static let chordActions: [Self] = [.insert, .discard]

    var defaultBinding: HotkeySpec {
        switch self {
        case .magic: .modifier(.rightCommand)
        case .insert: .combo(keyCode: UInt16(kVK_RightArrow), modifiers: [])
        case .discard: .combo(keyCode: UInt16(kVK_LeftArrow), modifiers: [])
        }
    }

    func accepts(_ binding: HotkeySpec) -> Bool {
        if case .combo = binding { return true }
        return self == .magic
    }

    @MainActor func isAvailable(in session: MacDictationSession, duringMagicHold: Bool = false) -> Bool {
        guard let draft = session.composer else { return false }
        switch self {
        case .discard:
            return session.isActivityInteractive && !draft.isInserting
                && (duringMagicHold || session.phase != .starting) && (!draft.isEmpty || session.isActive)
        case .magic, .insert:
            return session.isActivityInteractive && !draft.isEmpty && !draft.isCorrecting && !draft.isInserting
                && ((duringMagicHold && self == .insert) || (session.phase != .starting && session.speechMode != .instruction))
        }
    }
}
