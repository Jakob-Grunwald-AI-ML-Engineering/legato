import Foundation
@testable import LegatoMac

/// An in-memory text field counting in UTF-16 units, with fault injection.
@MainActor
final class FakeTextTarget: TextTarget {
    struct Failure: Error {}

    private(set) var units: [UInt16]
    private(set) var selection: UTF16Range
    /// Every attempted write, in order (including ones that were ignored, lied about or failed).
    private(set) var writes: [(range: UTF16Range, text: String)] = []
    private var successfulWrites = 0

    // Fault injection.
    var focused = true
    /// `replace` returns normally but changes nothing.
    var ignoreWrites = false
    /// `replace` returns normally but stores `x`s instead of the text.
    var lieOnWrites = false
    /// After this many successful writes, `replace` throws.
    var failWritesAfter: Int?
    var failReads = false
    var failSelection = false

    var string: String { String(decoding: units, as: UTF16.self) }

    /// `selection` defaults to a caret at the end of `text`.
    init(_ text: String = "", selection: UTF16Range? = nil) {
        units = Array(text.utf16)
        self.selection = selection ?? UTF16Range(location: text.utf16.count, length: 0)
    }

    /// The user edits the field behind the writer's back.
    func externalEdit(_ range: UTF16Range, with text: String) {
        splice(range, Array(text.utf16))
    }

    /// Like a real field, clamps the range to the text instead of trapping.
    private func splice(_ range: UTF16Range, _ new: [UInt16]) {
        let lower = min(max(range.location, 0), units.count)
        let upper = min(max(range.end, lower), units.count)
        units.replaceSubrange(lower..<upper, with: new)
    }

    func isFocused() -> Bool { focused }

    func selectedRange() throws -> UTF16Range {
        if failSelection { throw Failure() }
        return selection
    }

    func text(in range: UTF16Range) throws -> String {
        if failReads { throw Failure() }
        let lower = min(max(range.location, 0), units.count)
        let upper = min(max(range.end, lower), units.count)
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    func replace(_ range: UTF16Range, with text: String) throws {
        writes.append((range, text))
        if let limit = failWritesAfter, successfulWrites >= limit { throw Failure() }
        successfulWrites += 1
        if ignoreWrites { return }
        let stored = lieOnWrites ? String(repeating: "x", count: text.utf16.count) : text
        let new = Array(stored.utf16)
        splice(range, new)
        selection = UTF16Range(location: range.location + new.count, length: 0)
    }
}
