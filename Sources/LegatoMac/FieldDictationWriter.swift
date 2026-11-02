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
    /// Typed key by key (synthetic events), nothing on the pasteboard.
    case typed
    /// Typing stopped half-way (the app changed, or the user typed): `remainder` is on the clipboard.
    case interrupted(remainder: String, message: String)
    /// Left on the clipboard; `message` says why, for the notice.
    case copied(message: String)
}

/// The last dictation text this Mac delivered, to space the next dictation when its field cannot be read.
public struct DeliveryMemory: Sendable, Equatable {
    /// A dictation into the same app within this long continues the text.
    public static let window: TimeInterval = 600
    public var pid: Int32
    public var time: Date
    public var lastCharacter: Character
    /// The caret after the delivery, when the field was readable.
    public var caret: Int?

    public init(pid: Int32, time: Date, lastCharacter: Character, caret: Int? = nil) {
        self.pid = pid; self.time = time; self.lastCharacter = lastCharacter; self.caret = caret
    }

    /// The space (or nothing) to put before `text` when it is the first write of a new dictation into a field
    /// that cannot be read. `currentCaret` is the field's caret now, when it can be read at all.
    public func separator(before text: String, pid: Int32?, now: Date, currentCaret: Int?) -> String {
        guard pid == self.pid, now >= time, now.timeIntervalSince(time) <= Self.window,
              !lastCharacter.isWhitespace else { return "" }
        if let caret, let currentCaret, caret != currentCaret { return "" }
        return FieldDictationWriter.separator(before: text, after: lastCharacter, first: false)
    }
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
    private let typewriter: @MainActor () -> Bool
    private let sleep: (Duration) async -> Void
    private let frontmostApp: @MainActor () -> Int32?
    private let now: @MainActor () -> Date
    private var current: Current?
    /// Survives `begin()`: the next dictation continues this text when the field is unreadable.
    private var lastDelivery: DeliveryMemory?
    private var lines = 0
    private var copied = ""
    /// Characters of the field's text before the cursor handed to cleanup.
    public static let contextLimit = 600

    public init(capture: @escaping @MainActor () -> FocusedField,
                fallback: @escaping @MainActor (_ text: String, _ secure: Bool, _ copyOnly: Bool) async -> FallbackResult,
                typewriter: @escaping @MainActor () -> Bool = { false },
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                frontmostApp: @escaping @MainActor () -> Int32? = { nil },
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.capture = capture; self.fallback = fallback
        self.typewriter = typewriter; self.sleep = sleep; self.frontmostApp = frontmostApp; self.now = now
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
        if resolve() != nil, let outcome = await type(text, retry: true) {
            if outcome == .typed { copied = "" }
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

    /// Types `text`; nil when the field cannot take it (the caller falls back). Word by word when the typewriter is
    /// on; if the field stops taking text half-way, the untyped rest goes to the clipboard.
    private func type(_ text: String, retry: Bool) async -> Outcome? {
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
        let writer = field.writer
        var remainder: String?
        var wroteAny = false
        if typewriter() {
            let result = await Typewriter.run(delta, sleep: sleep) { step in
                writer.apply(.commit(delta: step))
                return writer.degradeReason == nil
            }
            remainder = result.remainder; wroteAny = result.wroteAny
        } else {
            writer.apply(.commit(delta: delta))
            if writer.degradeReason != nil { remainder = delta }
        }
        guard let remainder else {
            field.lastCharacter = delta.last
            current = field
            remember(lastCharacter: delta.last, caret: try? field.target.selectedRange().location)
            return .typed
        }
        let reason = writer.degradeReason
        current = nil
        guard wroteAny else {
            // The user edited the field between lines: start over at the cursor once.
            if retry, reason == .drift, case .target(let target) = capture() {
                current = Current(target: target, writer: FieldWriter(target: target, mode: .streamCommitted))
                return await type(text, retry: false)
            }
            return nil
        }
        // Part of the take is in the field and the writer stopped (clicked away, typed over): never type the rest
        // anywhere else; it goes to the clipboard.
        let typed = String(delta.unicodeScalars.dropLast(remainder.unicodeScalars.count))
        remember(lastCharacter: typed.last, caret: nil)
        let rest = String(remainder.drop(while: \.isWhitespace))
        copied = rest
        _ = await fallback(rest, false, true)
        return .copied(message: "Typing stopped: the rest is on the clipboard. Paste with ⌘V.")
    }

    private func remember(lastCharacter: Character?, caret: Int?) {
        guard let lastCharacter, let pid = frontmostApp() else { lastDelivery = nil; return }
        lastDelivery = DeliveryMemory(pid: pid, time: now(), lastCharacter: lastCharacter, caret: caret)
    }

    private func precedingCharacter(in target: any TextTarget) -> Character? {
        guard let selection = try? target.selectedRange(), selection.location > 0 else { return nil }
        return (try? target.text(in: UTF16Range(location: selection.location - 1, length: 1)))?.last
    }

    /// A space between the text before and the new line, unless one is already there or not wanted.
    nonisolated static func separator(before text: String, after previous: Character?, first: Bool) -> String {
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
            payload = (lines > 0 ? Self.separator(before: body, after: "x", first: false) : memorySeparator(before: body, copyOnly: copyOnly)) + body
        }
        switch await fallback(payload, secure, copyOnly) {
        case .pasted:
            remember(lastCharacter: payload.last, caret: nil)
            return .pasted
        case .typed:
            copied = ""
            remember(lastCharacter: payload.last, caret: nil)
            return .typed
        case .interrupted(let remainder, let message):
            copied = remainder
            let typed = String(payload.unicodeScalars.dropLast(remainder.unicodeScalars.count))
            remember(lastCharacter: typed.last, caret: nil)
            return .copied(message: message)
        case .copied(let message):
            copied = payload
            return .copied(message: message)
        }
    }

    /// The space a new dictation needs before its first text when the field could not be read: the last delivery
    /// went to the same app a moment ago and ended in a character that wants a space after it.
    private func memorySeparator(before body: String, copyOnly: Bool) -> String {
        guard !copyOnly, let lastDelivery else { return "" }
        let caret = current.flatMap { try? $0.target.selectedRange().location }
        return lastDelivery.separator(before: body, pid: frontmostApp(), now: now(), currentCaret: caret)
    }
}
