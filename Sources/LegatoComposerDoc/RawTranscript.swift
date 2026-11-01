import Foundation

public struct RawTranscript: Codable, Equatable, Sendable {
    public private(set) var segments: [[Word]] = []
    public var text: String { segments.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") }
    mutating func append(_ words: [Word]) { segments.append(words) }
}
