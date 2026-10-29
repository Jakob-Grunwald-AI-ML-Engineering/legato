import Foundation

/// One range replace: `span` (UTF-16, against a known ``FieldVersion``) becomes `text`. `expect` is the text the
/// step expects at `span`; it is a guard checked right before writing, never a search.
public struct EditStep: Sendable, Hashable, Codable {
    public var span: Span
    public var text: String
    public var expect: String

    public init(span: Span, text: String, expect: String) {
        self.span = span
        self.text = text
        self.expect = expect
    }

    /// Inserting `text` at `location`.
    public static func insert(_ text: String, at location: Int) -> EditStep {
        EditStep(span: .at(location), text: text, expect: "")
    }
}

extension EditStep {
    /// `text` with this step applied, or nil when `span` is out of range or does not hold `expect` byte for byte.
    public func apply(to text: String) -> String? {
        guard matches(text) else { return nil }
        return text.replacing(span, with: self.text)
    }

    /// Whether `text` holds `expect` at `span`, byte for byte.
    public func matches(_ text: String) -> Bool {
        guard let units = text.units(in: span) else { return false }
        return units.elementsEqual(expect.utf16)
    }
}
