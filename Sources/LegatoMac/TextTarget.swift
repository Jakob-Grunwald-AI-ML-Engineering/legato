import Foundation

/// A range of UTF-16 code units, the unit the macOS Accessibility API (and `NSString`) counts in.
/// (Not called `TextRange`: that name collides with a CoreServices C struct on macOS.)
public struct UTF16Range: Sendable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
}

/// The text field dictation writes into. Implemented over Accessibility on macOS and by a fake
/// in tests. Everything is synchronous and main-actor bound, like the AX calls behind it.
@MainActor
public protocol TextTarget: AnyObject {
    /// Whether the element this target was created for still has keyboard focus.
    func isFocused() -> Bool
    /// The current selection of the element; a caret is a range of length 0.
    func selectedRange() throws -> UTF16Range
    /// The text in `range`; may be shorter than requested near the end of the field.
    func text(in range: UTF16Range) throws -> String
    /// Replaces `range` with `text`, leaving the caret after the inserted text.
    func replace(_ range: UTF16Range, with text: String) throws
}
