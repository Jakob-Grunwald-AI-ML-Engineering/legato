import Foundation

/// How to deliver text that could not be inserted into the field directly.
public enum FallbackRoute: Sendable, Equatable {
    /// Put it on the pasteboard and synthesize ⌘V.
    case pasteKeystroke
    /// Only put it on the pasteboard: a synthesized ⌘V would need Accessibility, or would land
    /// in whatever app is in front now rather than where the dictation started.
    case copyOnly

    public static func route(axTrusted: Bool, frontmostIsTarget: Bool) -> FallbackRoute {
        axTrusted && frontmostIsTarget ? .pasteKeystroke : .copyOnly
    }
}
