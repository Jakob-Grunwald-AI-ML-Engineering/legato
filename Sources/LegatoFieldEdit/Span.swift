import Foundation

/// A range of the field in UTF-16 code units, the unit `NSRange`, AX and the text proxy's caret moves use.
/// `length == 0` is an insertion point.
public struct Span: Sendable, Hashable, Codable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    /// The insertion point at `location`.
    public static func at(_ location: Int) -> Span { Span(location: location, length: 0) }

    public var end: Int { location + length }
    public var isEmpty: Bool { length == 0 }
}
