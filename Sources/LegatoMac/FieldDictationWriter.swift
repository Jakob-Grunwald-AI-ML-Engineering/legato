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
    /// Left on the clipboard; `message` says why, for the notice, and `reason` whether the rest of the run follows.
    case copied(message: String, reason: CopyReason)
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
/// once one line was only copied for a lasting reason (secure field, app switched, no Accessibility) the rest of the
/// session is copied too, accumulated, so the clipboard holds the whole untyped text. A passing reason (modifiers
/// still held) does not latch: the text is carried into the next write, and `finish` retries what is left once
/// before it goes to the clipboard.
@MainActor
public final class FieldDictationWriter {
    public enum Outcome: Sendable, Equatable {
        case typed
        case pasted
        case copied(message: String)
        /// Held back (modifiers still down); goes out with the next write, or at `finish`.
        case held
        /// A streamed take whose cleanup failed: its typed part stays until `retractStreamed()`.
        case stalled
        /// A streamed take's typed part was taken back out of the field.
        case erased
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
    /// Keeps the typewriter on schedule when the field is slow to write (nil in tests on a virtual clock).
    private let pacingClock: ContinuousClock?
    private let frontmostApp: @MainActor () -> Int32?
    private let now: @MainActor () -> Date
    private var current: Current?
    /// Survives `begin()`: the next dictation continues this text when the field is unreadable.
    private var lastDelivery: DeliveryMemory?
    private var lines = 0
    /// Text that only reached the clipboard since a lasting reason latched the run to copy-only.
    private var copied = ""
    private var latched = false
    /// Text held back by a passing reason, written ahead of the next line.
    private var carried = ""
    /// What the last streamed take put into the field, kept until it is final or retracted.
    private struct Streamed {
        let writer: FieldWriter
        let target: any TextTarget
        /// Exactly what went through `writer`.
        var committed = ""
        /// A separator put into the field ahead of the writer's first write.
        var freshSeparator = ""
    }
    private var streamed: Streamed?
    /// A streaming frame: the poll and the drain step run this often.
    public static let streamTickMs = 30.0
    /// Characters of the field's text before the cursor handed to cleanup.
    public static let contextLimit = 600

    public init(capture: @escaping @MainActor () -> FocusedField,
                fallback: @escaping @MainActor (_ text: String, _ secure: Bool, _ copyOnly: Bool) async -> FallbackResult,
                typewriter: @escaping @MainActor () -> Bool = { false },
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                pacingClock: ContinuousClock? = ContinuousClock(),
                frontmostApp: @escaping @MainActor () -> Int32? = { nil },
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.capture = capture; self.fallback = fallback
        self.typewriter = typewriter; self.sleep = sleep; self.pacingClock = pacingClock; self.frontmostApp = frontmostApp; self.now = now
    }

    /// A session starts: forget the last one's field and clipboard run, capture the field in front now.
    public func begin() {
        current = nil; lines = 0; copied = ""; latched = false; carried = ""; streamed = nil
        _ = resolve()
    }

    /// The field's text before the cursor (at most `contextLimit` characters); empty when unreadable or secure.
    public func textBeforeCursor() -> String {
        guard let field = resolve(), let selection = try? field.target.selectedRange(), selection.location > 0 else { return "" }
        let start = max(0, selection.location - Self.contextLimit)
        return (try? field.target.text(in: UTF16Range(location: start, length: selection.location - start))) ?? ""
    }

    @discardableResult
    public func write(_ text: String) async -> Outcome { await write(text, final: false) }

    /// The session is over: whatever was held back is tried once more, then left on the clipboard.
    /// Nil when nothing was held.
    @discardableResult
    public func finish() async -> Outcome? {
        guard !carried.isEmpty else { return nil }
        let rest = carried
        carried = ""
        return await write(rest, final: true)
    }

    // MARK: Streaming

    /// Types one take that is still being cleaned. `poll` returns the take as it stands now (nil once it is gone).
    /// The text is typed as it grows: with the typewriter on, paced by the drain (`TypewriterPlan.drainStep`), else
    /// at once. The separator is decided once, from the first text. The caret is checked before every step and the
    /// writer's readback after it, so a field the user moved on in stops the typing; whatever is left of the take
    /// then goes to the clipboard. Where the field cannot be written through Accessibility the take is typed in one
    /// go when it is final (`write`). A failed take is left open (`.stalled`) until `retractStreamed()`.
    @discardableResult
    public func writeStreaming(poll: @MainActor () -> DictationStreamState?) async -> Outcome {
        streamed = nil
        var state = poll()
        // The first text (or the end).
        while let current = state, current.text.isEmpty, !current.isFinal, !current.retracted {
            if current.stalled { return .stalled }
            await sleep(.milliseconds(Self.streamTickMs))
            state = poll()
        }
        guard let first = state, !first.retracted else { return .erased }
        guard resolve() != nil, var field = current else { return await writeAfterStream(first, poll: poll) }
        let target = field.target, writer = field.writer
        var prefix = ""
        var run = Streamed(writer: writer, target: target)
        if let last = field.lastCharacter {
            prefix = Self.separator(before: first.text, after: last, first: false)
        } else {
            // A fresh writer drops leading whitespace, so the separator after the field's own text goes in first.
            let separator = Self.separator(before: first.text, after: precedingCharacter(in: target), first: true)
            if !separator.isEmpty, let caret = try? target.selectedRange(), caret.length == 0 {
                try? target.replace(caret, with: separator)
                run.freshSeparator = separator
            }
        }
        var revealed = 0, expected: UTF16Range?, stopped = false
        defer { lines += 1 }
        while let live = state {
            if live.retracted {
                streamed = run
                return stopped ? Self.leftInPlace : retractStreamed()
            }
            if !stopped {
                let total = live.text.count
                let next = typewriter() ? min(total, revealed + 1) : total
                if next > revealed {
                    let slice = String(live.text.dropFirst(revealed).prefix(next - revealed))
                    if !run.committed.isEmpty, (try? target.selectedRange()) != expected {
                        stopped = true // the user clicked elsewhere or typed at the end of our text
                    } else {
                        let delta = (run.committed.isEmpty ? prefix : "") + slice
                        writer.apply(.commit(delta: delta))
                        if writer.degradeReason != nil { stopped = true } else {
                            run.committed += delta; revealed = next; expected = try? target.selectedRange()
                        }
                    }
                }
            }
            if live.isFinal, stopped || revealed >= live.text.count { break }
            if live.stalled { streamed = run; return .stalled }
            await sleep(.milliseconds(Self.streamTickMs))
            state = poll()
        }
        guard let final = state else { // the take is gone (reset): what was typed stays
            self.current = nil
            return .typed
        }
        if !stopped {
            field.lastCharacter = final.text.last
            self.current = field
            remember(lastCharacter: final.text.last, caret: try? target.selectedRange().location)
            copied = ""; latched = false
            return .typed
        }
        self.current = nil
        guard !run.committed.isEmpty else {
            // The first write failed: nothing of the take is in the field. Write it again, whole, the usual way.
            return await write(final.text, final: false)
        }
        let typed = String(final.text.prefix(revealed))
        remember(lastCharacter: typed.last, caret: nil)
        let rest = String(final.text.dropFirst(revealed).drop(while: \.isWhitespace))
        guard !rest.isEmpty else { return .typed }
        copied = rest; latched = true
        _ = await fallback(rest, false, true)
        return .copied(message: "Typing stopped: the rest is on the clipboard. Paste with ⌘V.")
    }

    private static let leftInPlace = Outcome.copied(message: "The field changed, so the partial text was left where it is.")

    /// The take is not streamable here (no Accessibility field): wait for the end, then write it whole.
    private func writeAfterStream(_ first: DictationStreamState, poll: @MainActor () -> DictationStreamState?) async -> Outcome {
        var state: DictationStreamState? = first
        while let live = state, !live.isFinal {
            if live.retracted { return .erased }
            if live.stalled { streamed = nil; return .stalled }
            await sleep(.milliseconds(Self.streamTickMs))
            state = poll()
        }
        guard let final = state else { return .typed }
        return await write(final.text, final: false)
    }

    /// Takes the last streamed take back out of the field: only when the field and caret still read as the writer
    /// left them (`FieldWriter.retract`), else it stays and the user is told.
    @discardableResult
    public func retractStreamed() -> Outcome {
        guard let run = streamed else { return .erased }
        streamed = nil
        guard !run.committed.isEmpty else { return .erased }
        guard run.target.isFocused(), run.writer.retract(run.committed) == .removed else { return Self.leftInPlace }
        let length = run.freshSeparator.utf16.count
        if length > 0, let caret = try? run.target.selectedRange(), caret.length == 0, caret.location >= length {
            let range = UTF16Range(location: caret.location - length, length: length)
            if (try? run.target.text(in: range)) == run.freshSeparator { try? run.target.replace(range, with: "") }
        }
        current = nil // a new writer picks the field up at the caret
        return .erased
    }

    private func write(_ incoming: String, final: Bool) async -> Outcome {
        guard !incoming.allSatisfy({ $0 == " " }) else { return .typed }
        defer { lines += 1 }
        var text = incoming
        if !carried.isEmpty {
            text = carried + (text.first?.isNewline == true ? "" : Self.separator(before: text, after: "x", first: false)) + text
            carried = ""
        }
        if resolve() != nil, let outcome = await type(text, retry: true) {
            if outcome == .typed { copied = ""; latched = false }
            return outcome
        }
        // Nothing typable (or the write failed). A secure field never gets a paste, and once a line was only
        // copied for a lasting reason the rest of the run is too, so the clipboard holds all of it.
        return await deliver(text, secure: lastWasSecure, copyOnly: lastWasSecure || latched, final: final)
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
            current = Current(target: target, writer: FieldWriter(target: target, mode: .streamCommitted, characterEdits: typewriter()))
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
            // Between words the caret must still sit right after our text: the writer verifies its own span, not
            // that the user clicked elsewhere or typed at its end.
            let target = field.target
            var expected: UTF16Range?
            var started = false
            let result = await Typewriter.run(delta, sleep: sleep, clock: pacingClock) { step in
                if started {
                    guard let now = try? target.selectedRange(), now == expected else { return false }
                }
                writer.apply(.commit(delta: step))
                guard writer.degradeReason == nil else { return false }
                expected = try? target.selectedRange()
                started = true
                return true
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
                current = Current(target: target, writer: FieldWriter(target: target, mode: .streamCommitted, characterEdits: typewriter()))
                return await type(text, retry: false)
            }
            return nil
        }
        // Part of the take is in the field and the writer stopped (clicked away, typed over): never type the rest
        // anywhere else; it goes to the clipboard.
        let typed = String(delta.unicodeScalars.dropLast(remainder.unicodeScalars.count))
        remember(lastCharacter: typed.last, caret: nil)
        let rest = String(remainder.drop(while: \.isWhitespace))
        copied = rest; latched = true
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

    private func deliver(_ text: String, secure: Bool, copyOnly: Bool, final: Bool) async -> Outcome {
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
            copied = ""; latched = false
            remember(lastCharacter: payload.last, caret: nil)
            return .typed
        case .interrupted(let remainder, let message):
            copied = remainder; latched = true
            let typed = String(payload.unicodeScalars.dropLast(remainder.unicodeScalars.count))
            remember(lastCharacter: typed.last, caret: nil)
            return .copied(message: message)
        case .copied(let message, let reason):
            guard reason.latches else {
                // Held modifiers pass. Wait for the next write; at the end of the run the clipboard has it.
                guard final else { carried = body; return .held }
                _ = await fallback(body, false, true)
                return .copied(message: reason.toast)
            }
            copied = payload; latched = true
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
