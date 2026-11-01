import Foundation
import LegatoCore

/// What `FieldDictationWriter` found in front when it looked for a field.
public enum FocusedField {
    /// A text element writable with Accessibility.
    case target(any TextTarget)
    /// No usable element: text goes by paste, where that is allowed.
    case none
    /// A secure field (or one that could not be ruled out): never written, never pasted; copy only.
    case secure
}

/// How text that could not be typed was delivered instead.
public enum FallbackResult: Sendable, Equatable {
    case pasted
    /// Left on the clipboard; `message` says why, for the notice.
    case copied(message: String)
}

/// Types a dictation's cleaned lines into the focused field, one line at a time (Accessibility insert through
/// `FieldWriter`, paste fallback). The target is captured when the session starts (`begin`); every later line goes
/// to that field while it keeps focus and to the newly focused field when it does not. Lines that cannot be typed
/// (no field, secure field, a write the readback does not show) are pasted, or copied when pasting is not safe;
/// once one line was only copied the rest of the session is copied too, accumulated, so the clipboard holds the
/// whole untyped text.
@MainActor
public final class FieldDictationWriter {
    public enum Outcome: Sendable, Equatable {
        case typed
        case pasted
        case copied(message: String)
    }
    private struct Current {
        let target: any TextTarget
        var writer: FieldWriter
        /// The last character this session put into the field (nil until the first write).
        var lastCharacter: Character?
    }
    private let capture: @MainActor () -> FocusedField
    /// Delivers text that is not typed: `copyOnly` forbids a synthesized paste.
    private let fallback: @MainActor (_ text: String, _ secure: Bool, _ copyOnly: Bool) async -> FallbackResult
    private var current: Current?
    private var lines = 0
    private var copied = ""
    /// Characters of the field's text before the cursor handed to cleanup.
    public static let contextLimit = 600

    public init(capture: @escaping @MainActor () -> FocusedField,
                fallback: @escaping @MainActor (_ text: String, _ secure: Bool, _ copyOnly: Bool) async -> FallbackResult) {
        self.capture = capture; self.fallback = fallback
    }

    /// A session starts: forget the last one's field and clipboard run, capture the field in front now.
    public func begin() {
        current = nil; lines = 0; copied = ""
        _ = resolve()
    }

    /// The field's text before the cursor (at most `contextLimit` characters); empty when unreadable or secure.
    public func textBeforeCursor() -> String {
        guard let field = resolve(), let selection = try? field.target.selectedRange(), selection.location > 0 else { return "" }
        let start = max(0, selection.location - Self.contextLimit)
        return (try? field.target.text(in: UTF16Range(location: start, length: selection.location - start))) ?? ""
    }

    @discardableResult
    public func write(_ text: String) async -> Outcome {
        guard !text.allSatisfy({ $0 == " " }) else { return .typed }
        defer { lines += 1 }
        if resolve() != nil, let outcome = type(text, retry: true) {
            copied = ""
            return outcome
        }
        // Nothing typable (or the write failed). A secure field never gets a paste, and once a line was only
        // copied the rest of the run is too, so the clipboard holds all of it.
        return await deliver(text, secure: lastWasSecure, copyOnly: lastWasSecure || !copied.isEmpty)
    }

    // MARK: Typing

    private var lastWasSecure = false

    /// The field to write into now: the current one while it has focus, else whatever has focus.
    private func resolve() -> Current? {
        if let current, current.target.isFocused() { return current }
        current = nil
        switch capture() {
        case .target(let target):
            lastWasSecure = false
            current = Current(target: target, writer: FieldWriter(target: target, mode: .streamCommitted))
        case .secure: lastWasSecure = true
        case .none: lastWasSecure = false
        }
        return current
    }

    /// Types `text`; nil when the field cannot take it (the caller falls back).
    private func type(_ text: String, retry: Bool) -> Outcome? {
        guard var field = current else { return nil }
        var delta = text
        if let last = field.lastCharacter {
            delta = Self.separator(before: text, after: last, first: false) + text
        } else {
            // A fresh writer drops leading whitespace, so the separator after the field's own text goes in first.
            let before = precedingCharacter(in: field.target)
            let separator = Self.separator(before: text, after: before, first: true)
            if !separator.isEmpty, let caret = try? field.target.selectedRange(), caret.length == 0 {
                try? field.target.replace(caret, with: separator)
            }
        }
        field.writer.apply(.commit(delta: delta))
        guard field.writer.degradeReason == nil else {
            let reason = field.writer.degradeReason
            current = nil
            // The user edited the field between lines: start over at the cursor once.
            if retry, reason == .drift, case .target(let target) = capture() {
                current = Current(target: target, writer: FieldWriter(target: target, mode: .streamCommitted))
                return type(text, retry: false)
            }
            return nil
        }
        field.lastCharacter = delta.last
        current = field
        return .typed
    }

    private func precedingCharacter(in target: any TextTarget) -> Character? {
        guard let selection = try? target.selectedRange(), selection.location > 0 else { return nil }
        return (try? target.text(in: UTF16Range(location: selection.location - 1, length: 1)))?.last
    }

    /// A space between the text before and the new line, unless one is already there or not wanted.
    static func separator(before text: String, after previous: Character?, first: Bool) -> String {
        guard let next = text.first, !next.isWhitespace, !".,;:!?)]}%".contains(next) else { return "" }
        guard let previous else { return first ? "" : " " } // empty field, or unreadable
        if previous.isWhitespace || "([{\"'“‘„«¿¡".contains(previous) { return "" }
        return " "
    }

    // MARK: Fallback

    private func deliver(_ text: String, secure: Bool, copyOnly: Bool) async -> Outcome {
        let body = text.trimmingCharacters(in: .whitespaces)
        let payload: String
        if copyOnly, !copied.isEmpty {
            payload = copied + (body.first?.isNewline == true ? "" : Self.separator(before: body, after: "x", first: false)) + body
        } else {
            payload = (lines > 0 ? Self.separator(before: body, after: "x", first: false) : "") + body
        }
        switch await fallback(payload, secure, copyOnly) {
        case .pasted:
            return .pasted
        case .copied(let message):
            copied = payload
            return .copied(message: message)
        }
    }
}
