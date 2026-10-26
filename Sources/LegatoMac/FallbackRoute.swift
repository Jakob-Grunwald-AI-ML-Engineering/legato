import Foundation

/// How to deliver text that could not be inserted into the field directly.
public enum FallbackRoute: Sendable, Equatable {
    /// Put it on the pasteboard and synthesize ⌘V.
    case pasteKeystroke
    /// Only put it on the pasteboard: a synthesized ⌘V would need Accessibility, or would land
    /// in whatever app is in front now rather than where the dictation started.
    case copyOnly

    /// Paste only when every guard holds: Accessibility is granted, the app the dictation started
    /// in is still in front, the field is not a secure one, and the hotkey's modifiers are up
    /// (a ⌘V typed while they are down would arrive as another shortcut).
    public static func route(
        axTrusted: Bool,
        frontmostIsTarget: Bool,
        secureField: Bool = false,
        modifiersReleased: Bool = true
    ) -> FallbackRoute {
        axTrusted && frontmostIsTarget && !secureField && modifiersReleased ? .pasteKeystroke : .copyOnly
    }
}
