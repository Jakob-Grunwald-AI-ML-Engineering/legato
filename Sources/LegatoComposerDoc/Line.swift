import Foundation

public enum LineKind: String, Codable, Sendable { case p, li, oli, h1, h2, h3, quote }

public struct Line: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var kind: LineKind
    public var version: Int
    public var words: [Word]
    public var text: String { words.map(\.text).joined(separator: " ") }
    public init(id: String = "L" + UUID().uuidString, kind: LineKind = .p, version: Int = 0, words: [Word]) {
        self.id = id; self.kind = kind; self.version = version; self.words = words
    }
}

public struct DocumentSnapshot: Codable, Equatable, Sendable {
    public let revision: Int
    public let lines: [Line]
    public var text: String { lines.map(\.text).joined(separator: "\n") }
    public init(revision: Int, lines: [Line]) { self.revision = revision; self.lines = lines }
}
