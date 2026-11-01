import Foundation

/// The accepted words of one validated dictation admission, never an agent rewrite.
public struct DictationCommit: Codable, Equatable, Sendable {
    public static let maximumWords = 64
    public let sequence: Int
    public let wordIDs: [String]
    public let uptime: Double
    public init(sequence: Int, wordIDs: [String], uptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.sequence = sequence; self.uptime = uptime
        var seen = Set<String>()
        self.wordIDs = Array(wordIDs.reversed().filter { seen.insert($0).inserted }.prefix(Self.maximumWords).reversed())
    }
}
