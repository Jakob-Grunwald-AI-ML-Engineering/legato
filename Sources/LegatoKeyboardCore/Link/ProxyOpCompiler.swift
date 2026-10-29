import Foundation
import LegatoFieldEdit

/// One call on the text proxy, as the field edit queue's executor makes them. Unlike ``ProxyOp`` (the planner's
/// edits at the caret), it can move the caret, so a write can patch text before or after it and come back.
public enum ProxyCall: Sendable, Equatable {
    /// `adjustTextPosition(byCharacterOffset:)`: the proxy moves by UTF-16 units despite the name.
    case moveCaret(utf16: Int)
    /// This many `deleteBackward()` calls, one Character (grapheme cluster) each.
    case deleteBackward(Int)
    case insert(String)
}

/// Turns one ``FieldWrite`` of the edit queue into text proxy calls: for each step (highest location first, so
/// the lower spans stay valid) move to the span's end, delete its expected text backwards, insert its text;
/// then move to the write's caret. Moves count UTF-16 units, deletes count the Characters the expected text has
/// in the window (an emoji, a ZWJ sequence or a decomposed accent is one delete of several units).
public enum ProxyOpCompiler {
    /// The calls for `write`, issued against the caret-relative `window` with the caret at `caret` (UTF-16;
    /// the queue's ``ShadowDocument`` right before ``FieldEditQueue/next()``). Nil when a step does not hold its
    /// expected text there or reaches outside the window: nothing may be written then.
    public static func compile(_ write: FieldWrite, window: String, caret: Int) -> [ProxyCall]? {
        compile(steps: write.steps, caret: write.caret, window: window, from: caret)
    }

    /// The calls for `steps` (in application order) on `window` with the caret at `from`, ending at `caret`.
    public static func compile(steps: [EditStep], caret: Int, window: String, from: Int) -> [ProxyCall]? {
        var calls: [ProxyCall] = []
        var text = window
        var position = from
        func move(to target: Int) {
            if target != position { calls.append(.moveCaret(utf16: target - position)) }
            position = target
        }
        for step in steps {
            guard step.matches(text), let deleted = characterCount(in: text, span: step.span) else { return nil }
            move(to: step.span.end)
            if deleted > 0 { calls.append(.deleteBackward(deleted)) }
            if !step.text.isEmpty { calls.append(.insert(step.text)) }
            guard let next = step.apply(to: text) else { return nil }
            text = next
            position = step.span.location + step.text.utf16.count
        }
        guard caret >= 0, caret <= text.utf16.count else { return nil }
        move(to: caret)
        return calls
    }

    /// How many Characters of `text` lie in `span`, or nil when the span splits one (a delete could not take
    /// exactly that text).
    static func characterCount(in text: String, span: Span) -> Int? {
        var offset = 0, count = 0
        var startsOnBoundary = span.location == 0, endsOnBoundary = span.end == 0
        for character in text {
            if offset >= span.location, offset < span.end { count += 1 }
            offset += character.utf16.count
            if offset == span.location { startsOnBoundary = true }
            if offset == span.end { endsOnBoundary = true }
            if offset > span.end { break }
        }
        return startsOnBoundary && endsOnBoundary ? count : nil
    }
}
