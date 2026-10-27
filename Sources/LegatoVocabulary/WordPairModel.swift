import Foundation
import NaturalLanguage

/// Which word tends to follow which: a bigram model small enough for the keyboard extension.
///
/// A lowercase previous word maps to up to ``maxNext`` next words, each with its display form (as last written)
/// and a weight that decays with ``Decay`` (the weight is never rewritten as time passes; it is read through
/// ``Decay/effectiveScore(_:lastSeen:now:halfLife:)``). At most ``maxPrevious`` previous words are kept, the
/// lightest going first. Pairs form only inside one sentence and only between words that follow each other
/// directly: a comma, a number or any other punctuation between two words breaks the chain.
///
/// The app writes one model from dictations and the keyboard another from typing, with ``WordPairStore``;
/// the keyboard reads both with ``read(from:)`` and combines them with ``merged(with:now:)``.
public struct WordPairModel: Sendable, Equatable, Codable {
    /// The schema version this build reads and writes.
    public static let currentVersion = 1
    /// How many previous words are kept (``observe(text:at:)`` may briefly hold ten percent more until ``prune(now:)``).
    public static let maxPrevious = 4_000
    /// How many next words each previous word keeps.
    public static let maxNext = 8
    /// A pair whose decayed weight falls below this is dropped by ``prune(now:)``.
    public static let minWeight = 0.01

    /// A word seen after a previous word.
    public struct Next: Sendable, Equatable, Codable {
        /// The form as last written ("Berlin", "fährt").
        public var word: String
        /// Accumulated evidence as of `lastSeen`.
        public var weight: Double
        public var lastSeen: Date

        public init(word: String, weight: Double, lastSeen: Date) {
            self.word = word
            self.weight = weight
            self.lastSeen = lastSeen
        }

        func effective(at now: Date) -> Double { Decay.effectiveScore(weight, lastSeen: lastSeen, now: now) }
    }

    public var version: Int
    /// The language codes the text was written in (informational; tokenization is language-neutral).
    public var languages: [String]
    var pairs: [String: [Next]]

    public init(languages: [String] = []) {
        version = Self.currentVersion
        self.languages = languages
        pairs = [:]
    }

    /// How many previous words the model holds.
    public var previousWordCount: Int { pairs.count }

    // MARK: learning

    /// Learns the word pairs of `text`: reinforces a known pair (its decayed weight plus one) or adds it.
    public mutating func observe(text: String, at now: Date) {
        for run in Self.runs(in: text) {
            for (previous, next) in zip(run, run.dropFirst()) {
                add(previous: Self.key(previous), next: next, now: now)
            }
        }
        // A little slack, so a stream of observations does not sort the whole table each time; stores prune before writing.
        if pairs.count > Self.maxPrevious + Self.maxPrevious / 10 { prune(now: now) }
    }

    /// Drops pairs that decayed below ``minWeight``, trims every list to ``maxNext``, and keeps the
    /// ``maxPrevious`` previous words with the most weight.
    public mutating func prune(now: Date = Date()) {
        var kept: [String: [Next]] = [:]
        for (key, list) in pairs {
            let live = Self.trimmed(list.filter { $0.effective(at: now) >= Self.minWeight }, now: now)
            if !live.isEmpty { kept[key] = live }
        }
        if kept.count > Self.maxPrevious {
            let total = { (list: [Next]) in list.reduce(0) { $0 + $1.effective(at: now) } }
            let ranked = kept.map { (key: $0.key, weight: total($0.value), seen: $0.value.map(\.lastSeen).max() ?? .distantPast) }
                .sorted {
                    if $0.weight != $1.weight { return $0.weight > $1.weight }
                    return $0.seen != $1.seen ? $0.seen > $1.seen : $0.key < $1.key
                }
            kept = Dictionary(uniqueKeysWithValues: ranked.prefix(Self.maxPrevious).map { ($0.key, kept[$0.key]!) })
        }
        pairs = kept
    }

    /// This model and `other` as one: weights of a shared pair add up (each decayed to the later sighting),
    /// the display form is the more recent one, the languages are united. Neither input changes.
    public func merged(with other: WordPairModel, now: Date = Date()) -> WordPairModel {
        var out = self
        for language in other.languages where !out.languages.contains(language) { out.languages.append(language) }
        for (key, list) in other.pairs {
            var mine = out.pairs[key] ?? []
            for next in list {
                if let i = mine.firstIndex(where: { Self.key($0.word) == Self.key(next.word) }) {
                    let a = mine[i]
                    let later = max(a.lastSeen, next.lastSeen)
                    let newer = next.lastSeen > a.lastSeen ? next : a
                    mine[i] = Next(
                        word: newer.word,
                        weight: Decay.effectiveScore(a.weight, lastSeen: a.lastSeen, now: later)
                            + Decay.effectiveScore(next.weight, lastSeen: next.lastSeen, now: later),
                        lastSeen: later)
                } else {
                    mine.append(next)
                }
            }
            out.pairs[key] = mine
        }
        out.prune(now: now)
        return out
    }

    // MARK: lookup

    /// The words most likely to follow `previous`, best first (display forms). Only the last word counts (a bigram).
    public func predict(after previous: [String], limit: Int = 3, now: Date = Date()) -> [String] {
        ranked(after: previous, now: now).prefix(max(0, limit)).map(\.word)
    }

    /// The words that follow the last of `previous` and start with `prefix` (compared case-insensitively), best first.
    public func complete(prefix: String, after previous: [String], limit: Int = 3, now: Date = Date()) -> [String] {
        let wanted = Self.key(prefix)
        guard !wanted.isEmpty else { return [] }
        return ranked(after: previous, now: now).filter { Self.key($0.word).hasPrefix(wanted) }
            .prefix(max(0, limit)).map(\.word)
    }

    /// The decayed weight of `word` after `previous`, if the pair is known.
    func weight(of word: String, after previous: String, now: Date) -> Double? {
        pairs[Self.key(previous)]?.first { Self.key($0.word) == Self.key(word) }?.effective(at: now)
    }

    // MARK: persistence

    /// Reads the model at `url` synchronously and read-only; `nil` when the file is missing, unreadable or of another version.
    public static func read(from url: URL) -> WordPairModel? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> WordPairModel? {
        struct Probe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.version == currentVersion else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(WordPairModel.self, from: data)
    }

    static func encode(_ model: WordPairModel) throws -> Data {
        let encoder = JSONEncoder()
        // Whole milliseconds, like the vocabulary file: the default strategy writes a Double with float noise.
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(model)
    }

    // MARK: private

    private func ranked(after previous: [String], now: Date) -> [Next] {
        guard let last = previous.last, let list = pairs[Self.key(last)] else { return [] }
        return list.sorted(by: { Self.precedes($0, $1, now: now) })
    }

    private static func precedes(_ a: Next, _ b: Next, now: Date) -> Bool {
        let (x, y) = (a.effective(at: now), b.effective(at: now))
        if x != y { return x > y }
        if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
        return a.word < b.word
    }

    private static func trimmed(_ list: [Next], now: Date) -> [Next] {
        list.count <= maxNext ? list : Array(list.sorted(by: { precedes($0, $1, now: now) }).prefix(maxNext))
    }

    private mutating func add(previous: String, next: String, now: Date) {
        guard !previous.isEmpty else { return }
        var list = pairs[previous] ?? []
        if let i = list.firstIndex(where: { Self.key($0.word) == Self.key(next) }) {
            list[i] = Next(word: next, weight: list[i].effective(at: now) + 1, lastSeen: now)
        } else {
            list.append(Next(word: next, weight: 1, lastSeen: now))
        }
        if list.count > Self.maxNext {
            // The word just seen is never the one evicted, or a new word could never start to grow.
            let victim = list.indices.filter { Self.key(list[$0].word) != Self.key(next) }.min { a, b in
                Self.precedes(list[b], list[a], now: now)
            }
            if let victim { list.remove(at: victim) }
        }
        pairs[previous] = list
    }

    /// The comparison key of a word: edge punctuation trimmed, lowercased.
    static func key(_ word: String) -> String {
        var s = Substring(word)
        while let f = s.first, !(f.isLetter || f.isNumber) { s.removeFirst() }
        while let l = s.last, !(l.isLetter || l.isNumber) { s.removeLast() }
        return s.lowercased()
    }

    /// The chains of directly adjacent words of each sentence. A token without a letter ends the chain, as does
    /// any non-space text between two words.
    static func runs(in text: String) -> [[String]] {
        var out: [[String]] = []
        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        sentences.enumerateTokens(in: text.startIndex..<text.endIndex) { sentenceRange, _ in
            let sentence = String(text[sentenceRange])
            let words = NLTokenizer(unit: .word)
            words.string = sentence
            var run: [String] = []
            var previousEnd: String.Index?
            words.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
                let word = String(sentence[range])
                let adjacent = previousEnd.map { sentence[$0..<range.lowerBound].allSatisfy(\.isWhitespace) } ?? true
                if !adjacent, !run.isEmpty { out.append(run); run = [] }
                if word.contains(where: \.isLetter) {
                    run.append(word)
                } else if !run.isEmpty {
                    out.append(run)
                    run = []
                }
                previousEnd = range.upperBound
                return true
            }
            if !run.isEmpty { out.append(run) }
            return true
        }
        return out.filter { $0.count > 1 }
    }
}
