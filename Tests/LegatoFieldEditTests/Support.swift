import Foundation
import LegatoFieldEdit

/// A Mac-style queue: the window is the whole field (absolute positions).
func macQueue(_ text: String, caret: Int? = nil) -> FieldEditQueue {
    FieldEditQueue(FieldSnapshot(window: text, caret: caret ?? text.utf16.count, windowBase: 0))
}

func replace(_ location: Int, _ expect: String, with text: String) -> EditStep {
    EditStep(span: Span(location: location, length: expect.utf16.count), text: text, expect: expect)
}

/// The host field after the executor ran `write` on it.
func execute(_ write: FieldWrite, on text: String) -> String {
    write.steps.reduce(text) { field, step in step.apply(to: field)! }
}

extension FieldEditQueue {
    /// A host read showing the field exactly as the queue predicts it.
    var predicted: FieldSnapshot {
        FieldSnapshot(window: document.window, caret: document.caret, windowBase: document.windowBase)
    }

    /// Issues and executes every eligible write on `field`, settling each against a read of it.
    @discardableResult
    mutating func drain(_ field: inout String) -> [FieldWrite] {
        var writes: [FieldWrite] = []
        while let write = next() {
            field = execute(write, on: field)
            writes.append(write)
            settle(FieldSnapshot(window: field, caret: write.caret, windowBase: document.windowBase))
        }
        return writes
    }

    /// The host edited the field by itself (the user typing on the Mac): `field` becomes `text`.
    mutating func hostEdit(_ field: inout String, to text: String, caret: Int? = nil) {
        field = text
        observe(FieldSnapshot(window: text, caret: caret ?? text.utf16.count, windowBase: document.windowBase))
    }
}
