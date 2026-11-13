import Foundation

/// The observable result of replacing the pre-insert selection. Posting keys alone does not establish delivery.
public struct FieldInsertionExpectation: Sendable, Equatable {
    public let insertedRange: UTF16Range
    public let caret: UTF16Range
    public let length: Int?
    private let text: String

    public init?(text: String, selection: UTF16Range, length: Int?) {
        guard !text.isEmpty, selection.location >= 0, selection.length >= 0,
              length.map({ $0 >= selection.end }) ?? true else { return nil }
        self.text = text
        insertedRange = UTF16Range(location: selection.location, length: text.utf16.count)
        caret = UTF16Range(location: insertedRange.end, length: 0)
        self.length = length.map { $0 - selection.length + text.utf16.count }
    }

    public func matches(selection: UTF16Range?, length: Int?, insertedText: String?, normalizeSpaces: Bool) -> Bool {
        guard selection == caret, self.length == nil || length == self.length, let insertedText else { return false }
        func normalized(_ value: String) -> String {
            normalizeSpaces ? value.replacingOccurrences(of: "\u{00A0}", with: " ") : value
        }
        return normalized(insertedText) == normalized(text)
    }
}
