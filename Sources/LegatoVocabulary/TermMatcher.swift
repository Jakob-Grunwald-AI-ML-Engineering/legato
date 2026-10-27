import Foundation

/// Finds the vocabulary terms a stretch of text sounds or looks like.
///
/// The matcher never changes text. It answers two questions: which terms are relevant to a text
/// (``hits(in:)``, ``cleanupTerms(for:)``) and which terms a single word or span could have been
/// (``candidates(for:limit:)``).
///
/// A span of one to three words is compared with a term's text, spellings and aliases. Both sides are
/// lowercased, stripped of everything but letters and digits (so "kuber netties" compares as
/// "kubernetties") and folded two ways, with umlauts expanded (ä→ae, ö→oe, ü→ue, ß→ss) and with plain
/// diacritic removal (ü→u), the better pair counting. A pair is a match when
///
/// - the shorter side is at least 0.75 of the longer (the length-ratio floor), and
/// - the edit similarity `1 - distance / length` reaches 0.8, **or** it reaches 0.5 and the two sound alike
///   (the Kölner or the Metaphone key agrees).
///
/// A span of several words is joined without spaces, which makes short terms match by accident ("in a" →
/// "Ina"), so it may only match a single-word term when the joined span has six letters or more and none of its
/// words has fewer than three; a multi-word term matches any span. Words of four letters or fewer must match exactly. A list of more than 100 terms raises the edit
/// threshold to 0.85 and wants both phonetic keys to agree instead of either. The score is `0.6 × similarity + 0.4` when the keys agree, and 1 for an
/// exact match.
public struct TermMatcher: Sendable {
    /// A term as the matcher sees it: the vocabulary side of a ``VocabularyEntry``.
    public struct Term: Sendable, Equatable {
        public var id: UUID
        public var text: String
        /// Alternative correct surfaces.
        public var spellings: [String]
        /// Known mishearings.
        public var aliases: [String]

        public init(id: UUID = UUID(), text: String, spellings: [String] = [], aliases: [String] = []) {
            self.id = id
            self.text = text
            self.spellings = spellings
            self.aliases = aliases
        }

        /// The matcher view of `entry`.
        public init(_ entry: VocabularyEntry) {
            self.init(id: entry.id, text: entry.text, spellings: entry.spellings, aliases: entry.aliases)
        }
    }

    /// One scored match of a span against a term.
    public struct Match: Sendable, Equatable {
        /// The matched term.
        public var termID: UUID
        /// The matched words, as indices into the words of the searched text.
        public var range: Range<Int>
        /// 0...1; 1 is an exact match.
        public var score: Double
        /// The text, spelling or alias of the term that matched.
        public var form: String
    }

    private struct Form: Sendable {
        var text: String
        var variants: [String]
        var koelner: String
        var metaphone: String
        var wordCount: Int
    }

    private struct Prepared: Sendable {
        var id: UUID
        var forms: [Form]
    }

    private let terms: [Prepared]
    private let editFloor: Double
    private let phoneticFloor: Double
    private let bothKeys: Bool
    private static let lengthRatioFloor = 0.75
    private static let shortWordLetters = 4
    private static let maxSpanWords = 3
    private static let minJoinedLetters = 6
    private static let minSpanWordLetters = 3

    public init(terms: [Term]) {
        self.terms = terms.map { term in
            Prepared(id: term.id, forms: ([term.text] + term.spellings + term.aliases).compactMap(Self.form))
        }
        let large = terms.count > 100
        editFloor = large ? 0.85 : 0.8
        phoneticFloor = 0.5
        bothKeys = large
    }

    /// The best match of each term within `text`, best score first (ties by position). A term appears once,
    /// at its best-scoring span of one to three words; different terms may share a span.
    public func hits(in text: String) -> [Match] {
        let words = Self.words(in: text)
        var best: [Int: Match] = [:]
        for start in words.indices {
            for length in 1...Self.maxSpanWords where start + length <= words.count {
                let span = Array(words[start..<start + length])
                for (i, match) in matches(of: span, range: start..<start + length) where match.score > (best[i]?.score ?? 0) {
                    best[i] = match
                }
            }
        }
        return best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The ids of the terms hit in `text`, best first: the ones worth listing for the cleanup model.
    public func cleanupTerms(for text: String) -> [UUID] { hits(in: text).map(\.termID) }

    /// The terms that `span` (a word, or up to a few words) could have been, best first, at most `limit`.
    /// The range of each match covers all the words of `span`.
    public func candidates(for span: String, limit: Int = 3) -> [Match] {
        let words = Self.words(in: span)
        guard !words.isEmpty, limit > 0 else { return [] }
        let found = matches(of: words, range: 0..<words.count).map(\.1)
        return Array(found.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: matching

    private func matches(of words: [String], range: Range<Int>) -> [(Int, Match)] {
        let joined = words.joined()
        // Words joined without spaces match a short term by accident ("in a" is not "Ina"). A multi-word span may
        // only match a single-word term when it is long enough and none of its words is tiny.
        let spanIsSolid = words.count == 1 || (joined.count >= Self.minJoinedLetters && words.allSatisfy { $0.count >= Self.minSpanWordLetters })
        let variants = Self.variants(of: joined)
        guard !variants.isEmpty else { return [] }
        let koelner = PhoneticKey.koelner(joined)
        let metaphone = PhoneticKey.metaphone(joined)
        var out: [(Int, Match)] = []
        for (i, term) in terms.enumerated() {
            var best: Match?
            for form in term.forms where spanIsSolid || form.wordCount > 1 {
                let k = !koelner.isEmpty && koelner == form.koelner
                let m = !metaphone.isEmpty && metaphone == form.metaphone
                let sounds = bothKeys ? (k && m) : (k || m)
                guard let score = score(variants, form.variants, sounds: sounds) else { continue }
                if score > (best?.score ?? 0) {
                    best = Match(termID: term.id, range: range, score: score, form: form.text)
                }
            }
            if let best { out.append((i, best)) }
        }
        return out
    }

    private func score(_ a: [String], _ b: [String], sounds: Bool) -> Double? {
        var best: Double?
        for x in a {
            for y in b {
                let (short, long) = (min(x.count, y.count), max(x.count, y.count))
                guard long > 0, Double(short) / Double(long) >= Self.lengthRatioFloor else { continue }
                if x == y { return 1 }
                if short <= Self.shortWordLetters { continue }
                let similarity = 1 - Double(Self.distance(x, y)) / Double(long)
                guard similarity >= editFloor || (sounds && similarity >= phoneticFloor) else { continue }
                let score = 0.6 * similarity + (sounds ? 0.4 : 0)
                if score > (best ?? 0) { best = score }
            }
        }
        return best
    }

    // MARK: normalization

    private static func form(_ text: String) -> Form? {
        let v = variants(of: text)
        guard !v.isEmpty else { return nil }
        return Form(
            text: text, variants: v, koelner: PhoneticKey.koelner(text), metaphone: PhoneticKey.metaphone(text),
            wordCount: words(in: text).count)
    }

    /// The words of `text`: runs of letters and digits.
    static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Lowercase letters and digits only, folded with umlaut expansion and with plain diacritic removal.
    private static func variants(of text: String) -> [String] {
        let lower = text.lowercased()
        var expanded = ""
        var plain = ""
        for ch in lower {
            switch ch {
            case "ä": expanded += "ae"; plain += "a"
            case "ö": expanded += "oe"; plain += "o"
            case "ü": expanded += "ue"; plain += "u"
            case "ß": expanded += "ss"; plain += "ss"
            default:
                let base = String(ch).folding(options: .diacriticInsensitive, locale: nil)
                expanded += base
                plain += base
            }
        }
        var out: [String] = []
        for v in [expanded, plain] {
            let kept = String(v.filter { $0.isLetter || $0.isNumber })
            if !kept.isEmpty, !out.contains(kept) { out.append(kept) }
        }
        return out
    }

    /// Levenshtein distance.
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
