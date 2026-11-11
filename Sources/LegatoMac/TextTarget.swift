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
    /// The document length, without moving the selection. Unsupported targets fail closed.
    func setSelectedRange(_ range: UTF16Range) throws
    func textLength() throws -> Int
    /// Replaces `range` with `text`, leaving the caret after the inserted text.
    func replace(_ range: UTF16Range, with text: String) throws
    /// Whether `replace` lands exactly, so the field can be edited live. False where the host reads but does not
    /// apply text writes (Chromium web content): dictation then types the finished take instead.
    var editsInPlace: Bool { get }
    /// Checks, before anything is written, that `replace(range, …)` can be issued now; it may move the selection.
    /// A throw here means the text was not touched.
    func prepareReplace(_ range: UTF16Range) throws
}

public enum TextTargetReadError: Error { case unsupported }
public extension TextTarget {
    var editsInPlace: Bool { true }
    func prepareReplace(_ range: UTF16Range) throws {}
    func setSelectedRange(_ range: UTF16Range) throws { throw TextTargetReadError.unsupported }
    func textLength() throws -> Int { throw TextTargetReadError.unsupported }
}

// Shared by the older dictation writer and fallback writer. Readable fields never replace
// an unchanged character, even when the caller requests a whole-span revision or undo.
public enum MinimalTextEditError: Error, Equatable { case notApplied, partialWrite }

extension TextTarget {
    public func replaceMinimally(_ range: UTF16Range, with text: String, characters: Bool = false) throws {
        // An append owns no existing character. Its caller verifies read-back and preserves
        // the distinction between ignored, truncated and throwing host writes.
        if range.length == 0, !characters { try replace(range, with: text); return }
        let original = try self.text(in: range)
        let plan = ShadowEditPlanner.plan(shadow: original, cursor: original.utf16.count, target: text, characters: characters)
        let edits = plan.ops.filter { if case .move = $0 { false } else { true } }
        if !characters, edits.count == 1 {
            switch edits[0] {
            case .insert(let insertion):
                var cursor = original.utf16.count
                for op in plan.ops { if case .move(let units) = op { cursor += units } else { break } }
                try replace(.init(location: range.location + cursor, length: 0), with: insertion)
            case .deleteBackward(let count):
                var cursor = original.utf16.count
                for op in plan.ops { if case .move(let units) = op { cursor += units } else { break } }
                let before = (original as NSString).substring(to: cursor)
                let length = String(before.suffix(count)).utf16.count
                try replace(.init(location: range.location + cursor - length, length: length), with: "")
            case .move: break
            }
            let end = UTF16Range(location: range.location + text.utf16.count, length: 0)
            if (try? self.text(in: .init(location: range.location, length: text.utf16.count))) == text,
               try selectedRange() != end { try setSelectedRange(end) }
            return
        }
        var document = original
        var cursor = original.utf16.count
        var selection = try selectedRange()
        var wroteAny = false
        for op in plan.ops {
            if case .move(let delta) = op { cursor += delta; continue }
            guard isFocused(), try selectedRange() == selection,
                  try self.text(in: .init(location: range.location, length: document.utf16.count)) == document
            else { throw TextTargetReadError.unsupported }
            let mutation: UTF16Range
            let insertion: String
            switch op {
            case .deleteBackward(let count):
                let before = (document as NSString).substring(to: cursor)
                let length = String(before.suffix(count)).utf16.count
                mutation = .init(location: range.location + cursor - length, length: length); insertion = ""
            case .insert(let value): mutation = .init(location: range.location + cursor, length: 0); insertion = value
            case .move: continue
            }
            do { try replace(mutation, with: insertion) }
            catch { if wroteAny { throw MinimalTextEditError.partialWrite }; throw error }
            wroteAny = true
            let local = NSRange(location: mutation.location - range.location, length: mutation.length)
            document = (document as NSString).replacingCharacters(in: local, with: insertion)
            cursor = mutation.location - range.location + insertion.utf16.count
            selection = .init(location: range.location + cursor, length: 0)
            guard isFocused(), try selectedRange() == selection,
                  try self.text(in: .init(location: range.location, length: document.utf16.count)) == document
            else { throw MinimalTextEditError.notApplied }
        }
        let end = UTF16Range(location: range.location + text.utf16.count, length: 0)
        if selection != end { try setSelectedRange(end) }
        guard isFocused(), try selectedRange() == end else { throw TextTargetReadError.unsupported }
    }
}
