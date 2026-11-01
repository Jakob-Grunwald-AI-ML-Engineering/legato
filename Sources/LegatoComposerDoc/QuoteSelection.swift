import Foundation

/// Stable word endpoints. A tap and a dragged quote use the same selection contract.
public struct QuoteSelection: Codable, Equatable, Sendable {
    public var lineID: String
    public var wordID: String
    public var endLineID: String
    public var endWordID: String
    public init(lineID: String, wordID: String, endLineID: String? = nil, endWordID: String? = nil) {
        self.lineID = lineID; self.wordID = wordID
        self.endLineID = endLineID ?? lineID; self.endWordID = endWordID ?? wordID
    }
    public var isSingleWord: Bool { lineID == endLineID && wordID == endWordID }
    public func resolved(in snapshot: DocumentSnapshot) -> Self? {
        guard let a = position(lineID, wordID, snapshot), let b = position(endLineID, endWordID, snapshot) else { return nil }
        return a <= b ? self : Self(lineID: endLineID, wordID: endWordID, endLineID: lineID, endWordID: wordID)
    }
    public func lines(in snapshot: DocumentSnapshot) -> [Line] {
        guard let value = resolved(in: snapshot), let a = position(value.lineID, value.wordID, snapshot),
              let b = position(value.endLineID, value.endWordID, snapshot) else { return [] }
        return Array(snapshot.lines[a.0...b.0])
    }
    public func wordIDs(in snapshot: DocumentSnapshot) -> Set<String> { Set(slices(in: snapshot).flatMap { $0.map(\.id) }) }
    public func quote(in snapshot: DocumentSnapshot) -> String { slices(in: snapshot).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") }
    private func slices(in snapshot: DocumentSnapshot) -> [[Word]] {
        guard let value = resolved(in: snapshot), let a = position(value.lineID, value.wordID, snapshot),
              let b = position(value.endLineID, value.endWordID, snapshot) else { return [] }
        return (a.0...b.0).map { index in
            let words = snapshot.lines[index].words
            guard !words.isEmpty else { return [] }
            return Array(words[(index == a.0 ? a.1 : 0)...(index == b.0 ? b.1 : words.count - 1)])
        }
    }
    private func position(_ line: String, _ word: String, _ snapshot: DocumentSnapshot) -> (Int, Int)? {
        guard let l = snapshot.lines.firstIndex(where: { $0.id == line }), let w = snapshot.lines[l].words.firstIndex(where: { $0.id == word }) else { return nil }
        return (l, w)
    }
}
