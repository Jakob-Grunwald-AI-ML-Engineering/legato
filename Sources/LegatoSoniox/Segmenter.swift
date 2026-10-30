import Foundation

public struct SonioxSegment: Codable, Sendable, Equatable {
    public var words: [TimedWord]
    public var reason: String
}
public struct SegmenterOutput: Sendable {
    public var segments: [SonioxSegment]
    public var tail: String
}

public struct Segmenter: Sendable {
    public let maxWords: Int
    public let maxDuration: Double
    public let gap: Double
    private var merger = WordMerger()
    private var words: [TimedWord] = []
    public init(maxWords: Int = 25, maxDuration: Double = 8, gap: Double = 0.7) {
        self.maxWords = max(1, maxWords); self.maxDuration = maxDuration; self.gap = gap
    }
    public mutating func ingest(_ tokens: [SonioxToken], finished: Bool = false) -> SegmenterOutput {
        var segments: [SonioxSegment] = []
        func close(_ reason: String) {
            guard !words.isEmpty else { return }
            segments.append(SonioxSegment(words: words, reason: reason)); words = []
        }
        func add(_ word: TimedWord) {
            if let start = word.t0, let end = words.last?.t1, start - end >= gap { close("gap") }
            words.append(word)
            if let last = word.word.text.last, ".!?。！？".contains(last) { close("punctuation") }
            else if words.count >= maxWords { close("words") }
            else if let start = words.first?.t0, let end = word.t1, end - start >= maxDuration { close("duration") }
        }
        for token in tokens where token.isFinal {
            if token.text == "<end>" || token.text == "<fin>" {
                if let pending = merger.flush() { add(pending) }; close(token.text == "<end>" ? "endpoint" : "finalize")
            } else {
                // A real pause is also a boundary when the provider omits leading whitespace.
                if let start = token.startMs, let end = merger.pending?.t1, start / 1000 - end >= gap {
                    if let pending = merger.flush() { add(pending) }; close("gap")
                }
                for word in merger.append(token) { add(word) }
            }
        }
        if finished { if let pending = merger.flush() { add(pending) }; close("finished") }
        let committedTail = words.map(\.word.text).joined(separator: " ")
        let pending = merger.pending?.word.text ?? ""
        let speculative = tokens.filter { !$0.isFinal && !$0.text.hasPrefix("<") }.map(\.text).joined()
        let tail = [committedTail, pending + speculative].filter { !$0.isEmpty }.joined(separator: " ")
        return SegmenterOutput(segments: segments, tail: tail)
    }
}
