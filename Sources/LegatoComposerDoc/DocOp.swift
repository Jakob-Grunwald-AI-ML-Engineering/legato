import Foundation

public enum DocOp: Codable, Equatable, Sendable {
    case insertLines(after: String?, lines: [Line])
    case deleteLines(ids: [String])
    case replaceLines(ids: [String], lines: [Line])
    case replaceInLine(lineID: String, old: String, new: String)
    case moveLines(ids: [String], after: String?)
    case setKind(ids: [String], kind: LineKind)
    case pinWord(lineID: String, wordID: String, text: String)
    case setAlternatives(lineID: String, wordID: String, alternatives: [String])
}

public enum DocumentError: Error, Equatable, Sendable {
    case unknownLine(String), duplicateID(String), versionConflict(String), pinnedWord(String)
    case ambiguousText, invalidOperation, undoUnavailable
    public var isError: Bool { true }
}
