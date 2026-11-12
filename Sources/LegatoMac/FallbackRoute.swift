import Foundation

/// Why a paste became a plain copy.
public enum CopyReason: Sendable, Equatable {
    case accessibilityMissing, secureField, appChanged, modifiersHeld

    /// Whether the cause outlasts the moment: a secure field, a switched app or missing Accessibility keep the rest
    /// of the run copy-only. Held modifiers pass, so the text waits for the next write instead.
    public var latches: Bool { self != .modifiersHeld }

    public var toast: String {
        switch self {
        case .accessibilityMissing: "Copied to the clipboard. Grant Accessibility to type into fields."
        case .secureField: "Dictation copied. Paste with ⌘V."
        case .appChanged: "You switched apps: copied to the clipboard, paste with ⌘V."
        case .modifiersHeld: "Keys were still held: copied to the clipboard, paste with ⌘V."
        }
    }
}

/// How to deliver text that could not be inserted into the field directly.
public enum FallbackRoute: Sendable, Equatable {
    /// Put it on the pasteboard and synthesize ⌘V.
    case pasteKeystroke
    /// Only put it on the pasteboard: a synthesized ⌘V would need Accessibility, would land in whatever app is in
    /// front now rather than where the dictation started, or would meet the hotkey's modifiers still held.
    case copyOnly(CopyReason)

    /// Paste only when every guard holds: Accessibility is granted, the app the dictation started
    /// in is still in front, the field is not a secure one, and the hotkey's modifiers are up
    /// (a ⌘V typed while they are down would arrive as another shortcut). The reason is the first
    /// guard that fails, most lasting first.
    public static func route(
        axTrusted: Bool,
        frontmostIsTarget: Bool,
        secureField: Bool = false,
        modifiersReleased: Bool = true
    ) -> FallbackRoute {
        if !axTrusted { return .copyOnly(.accessibilityMissing) }
        if secureField { return .copyOnly(.secureField) }
        if !frontmostIsTarget { return .copyOnly(.appChanged) }
        if !modifiersReleased { return .copyOnly(.modifiersHeld) }
        return .pasteKeystroke
    }
}

/// Waits for the hotkey's modifiers to come up before a synthesized ⌘V or typing, so the keystroke is not read
/// as another shortcut.
public enum ModifierWait {
    /// A generous bound, so a stuck key cannot block the run forever; normally the hotkey release ends the wait.
    public static let cap = Duration.seconds(30)

    /// Polls `held` until it is false; false when the cap passes or the task is cancelled with it still true.
    @MainActor
    public static func untilReleased(
        held: () -> Bool,
        poll: Duration = .milliseconds(20),
        cap: Duration = ModifierWait.cap,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        var waited = Duration.zero
        while held(), waited < cap, !Task.isCancelled {
            await sleep(poll)
            waited += poll
        }
        return !held()
    }
}

/// What the hotkey tap makes of a raw event.
public enum HotkeyTapFilter {
    /// The event the gesture should see, or nil for Legato's own synthetic events (typing, ⌘V), which never count
    /// as the user's keys or chords. Only the device-independent modifier bits are kept.
    public static func keyEvent(kind: KeyEvent.Kind, keyCode: UInt16, flagsRaw: UInt64, userData: Int64) -> KeyEvent? {
        guard !SyntheticEvent.isLegato(userData) else { return nil }
        return KeyEvent(kind: kind, keyCode: keyCode,
                        flags: ModifierFlags(rawValue: UInt(truncatingIfNeeded: flagsRaw) & 0xFFFF_0000))
    }
}
