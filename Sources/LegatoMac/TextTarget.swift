import Foundation
import LegatoKeyboardCore

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

/// What the Mac dictation found in front when it bound a field.
public enum FocusedField {
    /// A readable text element: written with Accessibility, or with verified keystrokes.
    case target(any TextTarget)
    /// No usable element: the take goes through the notch panel.
    case none
    /// A positively identified password field: never read or written live; the panel types its take once at the end,
    /// and the take is not kept in History.
    case password
}

/// One synthetic key the queue sends to a field that takes keystrokes: an arrow without modifiers, Backspace, or one
/// grapheme as a Unicode key event (a control character such as a line break goes as a guarded paste: Return and Tab
/// are never synthesized). Caret moves can also go as a short run of arrows, or as one hop with its modifier pressed
/// and released around it.
public enum FieldKey: Sendable, Equatable {
    case left, right, backspace
    case text(Character)
    /// `count` plain arrows in one posted sequence.
    case arrows(left: Bool, count: Int)
    case hop(CaretHop)
}

/// A caret move of one modified arrow key.
public enum CaretHop: String, Sendable, Equatable, CaseIterable {
    /// Option+Left / Option+Right: to the start of the word before, the end of the word after.
    case wordLeft, wordRight
    /// Command+Left / Command+Right: to the start / end of the line (a wrapped line's visual start or end).
    case lineStart, lineEnd
    /// Command+Up / Command+Down: to the start / end of the field.
    case documentStart, documentEnd
}

/// Why a key was not sent. Nothing reached the field.
public enum FieldKeyRefusal: Error, Sendable, Equatable {
    /// Another app is in front, or the bound element lost focus.
    case notFocused
    /// The user pressed a key or clicked since the step was planned.
    case userInput
    /// A modifier key is held down.
    case modifiersHeld
    /// The selection is not where the step was planned.
    case selectionMoved
    /// The key could not be built or posted.
    case unavailable
}

/// What `TextTarget.refocus(allowOther:)` found when the bound element no longer read as focused.
public enum FieldRefocus: Sendable, Equatable {
    /// Another app is in front, or nothing editable has focus: nothing changed.
    case lost
    /// The same app is in front with another editable text element focused that is not this editor, and another field
    /// was not allowed: nothing changed.
    case declined
    /// The target now reads and writes the focused element. `sameEditor`: it is this editor (the same element, a fresh
    /// element for it, an element inside it or its editable root); false: another editable field of the same app.
    case rebound(sameEditor: Bool)
}

/// The text field dictation writes into. Implemented over Accessibility on macOS and by a fake
/// in tests. Everything is synchronous and main-actor bound, like the AX calls behind it.
@MainActor
public protocol TextTarget: AnyObject {
    /// Whether the element this target is bound to still has keyboard focus.
    func isFocused() -> Bool
    /// The bound element lost focus: binds the target to the element that has it now when the same app is in front and
    /// that element is an editable text field of the same kind. A web page recreates elements when its DOM changes (a
    /// new line, a list item) and moves focus between nested elements, so the editor the user is typing in can be a new
    /// element. `allowOther`: another field of the same app may be bound too (nothing was written yet).
    func refocus(allowOther: Bool) -> FieldRefocus
    /// The current selection of the element; a caret is a range of length 0.
    func selectedRange() throws -> UTF16Range
    /// The text in `range`; may be shorter than requested near the end of the field.
    func text(in range: UTF16Range) throws -> String
    func setSelectedRange(_ range: UTF16Range) throws
    /// The document length, without moving the selection. Unsupported targets fail closed.
    func textLength() throws -> Int
    /// Replaces `range` with `text`, leaving the caret after the inserted text.
    func replace(_ range: UTF16Range, with text: String) throws
    /// Whether `replace` lands exactly, so the field can be edited live with Accessibility writes. False where the
    /// host reads but does not apply text writes (Chromium web content).
    var editsInPlace: Bool { get }
    /// Whether the field is edited with synthetic keys instead (`press`), each one verified by reading it back.
    var typesKeys: Bool { get }
    /// A counter of the user's real key presses and clicks: a key planned at one mark is refused at another.
    var inputMark: Int { get }
    /// Sends one key, only if every guard holds now: the bound element has focus in the frontmost app, no real input
    /// since `mark`, no modifier held, and the selection is `selection`. Throws `FieldKeyRefusal` and sends nothing
    /// otherwise. Returning does not mean the key landed: the caller reads the field back.
    func press(_ key: FieldKey, mark: Int, selection: UTF16Range) throws
    /// Sets the selection through Accessibility under the same guards as `press` (focus, no real input since `mark`,
    /// the selection still `selection`). Returning does not mean it took: the caller reads it back.
    func setCaret(_ range: UTF16Range, mark: Int, selection: UTF16Range) throws
    /// Identifies the field across bindings (the same element bound again), so what the queue learned about it is
    /// remembered; nil when unknown.
    var fieldKey: AnyHashable? { get }
}

public enum TextTargetReadError: Error { case unsupported }
public extension TextTarget {
    var editsInPlace: Bool { true }
    var typesKeys: Bool { false }
    var inputMark: Int { 0 }
    func press(_ key: FieldKey, mark: Int, selection: UTF16Range) throws { throw FieldKeyRefusal.unavailable }
    func setCaret(_ range: UTF16Range, mark: Int, selection: UTF16Range) throws { throw FieldKeyRefusal.unavailable }
    var fieldKey: AnyHashable? { nil }
    func refocus(allowOther: Bool) -> FieldRefocus { .lost }
    func setSelectedRange(_ range: UTF16Range) throws { throw TextTargetReadError.unsupported }
    func textLength() throws -> Int { throw TextTargetReadError.unsupported }
}
