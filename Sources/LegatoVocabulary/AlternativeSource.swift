import Foundation

/// Where an alternative for a tapped word came from.
public enum AlternativeKind: String, Sendable, Codable, CaseIterable {
    /// A term of the personal vocabulary.
    case vocabulary
    /// A guess of the platform spell checker.
    case spellChecker
    /// An alternative the speech engine itself offered.
    case engine
}

/// The sentence a tapped word sits in.
public struct AlternativeContext: Sendable, Equatable {
    /// The whole sentence (or the text around the word).
    public var sentence: String
    /// The tapped word's range in `sentence`.
    public var wordRange: Range<String.Index>
    /// Bare language codes ("de", "en") to consult, best first.
    public var languages: [String]

    public init(sentence: String, wordRange: Range<String.Index>, languages: [String] = []) {
        self.sentence = sentence
        self.wordRange = wordRange
        self.languages = languages
    }

    /// The tapped word as written in the sentence.
    public var word: String { String(sentence[wordRange]) }
}

/// One suggested replacement and how much its source trusts it.
public struct ScoredCandidate: Sendable, Equatable {
    public var text: String
    /// 0...1, comparable only within the source that produced it; ``WordAlternatives`` adds a source prior.
    public var score: Double
    public var source: AlternativeKind

    public init(text: String, score: Double, source: AlternativeKind) {
        self.text = text
        self.score = min(1, max(0, score))
        self.source = source
    }
}

/// Something that can propose replacements for a word.
public protocol AlternativeSource: Sendable {
    func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate]
}

/// Vocabulary terms the tapped word, or the word together with its neighbours, sounds or looks like.
///
/// The matcher runs over the non-blocked entries. Spans of one to three words that contain the tapped word
/// are tried, so "kuber" in "kuber netties" yields "Kubernetes". The candidate text is the term's own text,
/// never an alias. A multi-word match proposes the term for the whole span; the caller decides what to replace.
public struct VocabularySource: AlternativeSource {
    private let matcher: TermMatcher
    private let texts: [UUID: String]

    public init(snapshot: VocabularySnapshot) {
        let live = snapshot.entries.filter { !$0.blocked }
        matcher = TermMatcher(terms: live.map(TermMatcher.Term.init))
        texts = Dictionary(live.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    public func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate] {
        var best: [UUID: Double] = [:]
        for span in Self.spans(around: context) {
            for match in matcher.candidates(for: span, limit: 3) where match.score > (best[match.termID] ?? 0) {
                best[match.termID] = match.score
            }
        }
        return best.compactMap { id, score in
            texts[id].map { ScoredCandidate(text: $0, score: score, source: .vocabulary) }
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }
    }

    /// The tapped word alone, then every run of two or three words in `context` that contains it.
    static func spans(around context: AlternativeContext) -> [String] {
        let sentence = context.sentence
        var words: [Range<String.Index>] = []
        var start: String.Index?
        var i = sentence.startIndex
        while i < sentence.endIndex {
            let part = sentence[i].isLetter || sentence[i].isNumber
            if part, start == nil { start = i }
            if !part, let s = start { words.append(s..<i); start = nil }
            i = sentence.index(after: i)
        }
        if let s = start { words.append(s..<sentence.endIndex) }
        guard let tapped = words.firstIndex(where: { $0.upperBound > context.wordRange.lowerBound }) else {
            return [context.word]
        }
        var spans = [String(sentence[words[tapped]])]
        for length in 2...3 {
            for first in max(0, tapped - length + 1)...tapped where first + length <= words.count {
                spans.append(words[first..<first + length].map { String(sentence[$0]) }.joined(separator: " "))
            }
        }
        return spans
    }
}

/// The spell checker's guesses for the tapped word, in each configured language.
///
/// A guess scores by its rank (0.8 for the first, 0.1 less for each next, at least 0.3); the guesses of
/// later languages follow those of earlier ones at a further 0.05 discount per language.
public struct SpellCheckerSource: AlternativeSource {
    private let checker: any SpellChecking
    private let languages: [String]?

    /// - Parameter languages: the codes to ask; `nil` takes the context's.
    public init(checker: any SpellChecking, languages: [String]? = nil) {
        self.checker = checker
        self.languages = languages
    }

    public func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate] {
        var out: [ScoredCandidate] = []
        for (n, language) in (languages ?? context.languages).enumerated() {
            let guesses = await checker.guesses(for: word, language: language)
            for (rank, guess) in guesses.enumerated() {
                out.append(ScoredCandidate(text: guess, score: max(0.3, 0.8 - 0.1 * Double(rank)) - 0.05 * Double(n), source: .spellChecker))
            }
        }
        return out
    }
}

/// Alternatives the caller already has from the speech engine (for example SpeechTranscriber's
/// `alternativeTranscriptions`, or a future n-best list), best first.
public struct EngineAlternativesSource: AlternativeSource {
    private let alternatives: [String]

    public init(_ alternatives: [String]) { self.alternatives = alternatives }

    /// The first scores 0.9, each next 0.1 less, at least 0.5.
    public func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate] {
        alternatives.enumerated().map { rank, text in
            ScoredCandidate(text: text, score: max(0.5, 0.9 - 0.1 * Double(rank)), source: .engine)
        }
    }
}

/// Exact mishearings learned from choices or repeated cleanup runs outrank fuzzy matches.
public struct CorrectionHistorySource: AlternativeSource {
    private let snapshot: VocabularySnapshot
    public init(snapshot: VocabularySnapshot) { self.snapshot = snapshot }
    public func candidates(for word: String, context: AlternativeContext) async -> [ScoredCandidate] {
        let key = VocabularyEntry.foldedKey(for: word)
        let learned = snapshot.entries.filter { !$0.blocked && $0.aliases.contains(where: { VocabularyEntry.foldedKey(for: $0) == key }) }
            .map { ScoredCandidate(text: $0.text, score: 1, source: .vocabulary) }
        let pending = snapshot.pendingFixes.filter { VocabularyEntry.foldedKey(for: $0.raw) == key && !snapshot.isBlocked($0.target) }
            .map { ScoredCandidate(text: $0.target, score: 0.95, source: .vocabulary) }
        return learned + pending
    }
}
