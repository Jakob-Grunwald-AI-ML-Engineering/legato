import Foundation

public struct SonioxSegment: Codable, Sendable, Equatable {
    public var words: [TimedWord]
    public var reason: String
}
public enum SegmenterEvent: Sendable {
    case segment(SonioxSegment)
    case boundary(reason: String, time: Double?)
}
public struct TailPart: Codable, Sendable {
    public var text: String
    public var time: Double?
}
public struct SegmenterOutput: Sendable {
    public var segments: [SonioxSegment]
    public var tail: String
    public var events: [SegmenterEvent]
    public var tailParts: [TailPart]
}

public struct Segmenter: Sendable {
    public let maxWords: Int
    public let maxDuration: Double
    public let gap: Double
    private var merger = WordMerger()
    private var words: [TimedWord] = []
    private var lastWordEnd: Double?
    private var hasUnclosedChunk = false
    public init(maxWords: Int = 25, maxDuration: Double = 8, gap: Double = 0.7) {
        self.maxWords = max(1, maxWords); self.maxDuration = maxDuration; self.gap = gap
    }
    public mutating func ingest(_ tokens: [SonioxToken], finished: Bool = false) -> SegmenterOutput {
        var segments: [SonioxSegment] = []
        var events: [SegmenterEvent] = []
        func close(_ reason: String) {
            if !words.isEmpty {
                let segment = SonioxSegment(words: words, reason: reason)
                segments.append(segment); events.append(.segment(segment)); words = []
            }
            // Silence/endpoint is a chunk boundary even when punctuation already flushed the words.
            if ["gap", "endpoint", "finalize", "finished"].contains(reason) {
                if reason != "gap" || hasUnclosedChunk {
                    events.append(.boundary(reason: reason, time: lastWordEnd))
                }
                hasUnclosedChunk = false
            }
        }
        func add(_ word: TimedWord) {
            if let start = word.t0, let end = lastWordEnd, hasUnclosedChunk, start - end >= gap { close("gap") }
            words.append(word)
            lastWordEnd = word.t1 ?? lastWordEnd
            hasUnclosedChunk = true
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
        var parts = words.enumerated().map { index, word in
            TailPart(text: (index == 0 ? "" : " ") + word.word.text, time: word.t0)
        }
        if let word = merger.pending { parts.append(TailPart(text: (parts.isEmpty ? "" : " ") + word.word.text, time: word.t0)) }
        parts += tokens.filter { !$0.isFinal && !$0.text.hasPrefix("<") }.map { TailPart(text: $0.text, time: $0.startMs.map { $0 / 1000 }) }
        return SegmenterOutput(segments: segments, tail: tail, events: events, tailParts: parts)
    }
}
