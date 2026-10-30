import Foundation
import LegatoComposerDoc

public struct TimedWord: Codable, Sendable, Equatable {
    public var word: Word
    /// Seconds relative to the audio stream.
    public var t0: Double?
    public var t1: Double?
}

/// Soniox final tokens are append-only; non-final tokens replace the previous speculative tail.
public struct WordMerger: Sendable {
    public private(set) var pending: TimedWord?
    public init() {}
    public mutating func flush() -> TimedWord? { defer { pending = nil }; return pending }
    public mutating func append(_ token: SonioxToken) -> [TimedWord] {
        guard token.isFinal, !token.text.hasPrefix("<") else { return [] }
        var output: [TimedWord] = []
        // A leading space marks a new word; punctuation/subword pieces attach to the current one.
        for part in token.text.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace) {
            if part.isEmpty { if let word = flush() { output.append(word) }; continue }
            let text = String(part)
            if pending == nil {
                pending = TimedWord(word: Word(text: text, confidence: token.confidence, language: token.language),
                                    t0: token.startMs.map { $0 / 1000 }, t1: token.endMs.map { $0 / 1000 })
            } else {
                pending?.word.text += text
                if let confidence = token.confidence { pending?.word.confidence = min(pending?.word.confidence ?? confidence, confidence) }
                if pending?.word.language == nil { pending?.word.language = token.language }
                if let end = token.endMs { pending?.t1 = end / 1000 }
            }
        }
        if let last = pending?.word.text.last, ".!?。！？".contains(last), let word = flush() { output.append(word) }
        return output
    }
}
