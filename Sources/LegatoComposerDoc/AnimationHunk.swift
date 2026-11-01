import Foundation

public enum AnimationHunk: Codable, Equatable, Sendable {
    case lineInserted(line: Line, index: Int)
    case lineDeleted(line: Line, index: Int)
    case lineMoved(lineID: String, from: Int, to: Int)
    case wordsReplaced(lineID: String, old: [Word], new: [Word])
}
