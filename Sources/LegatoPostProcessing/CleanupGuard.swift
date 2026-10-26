import Foundation

/// Rejects LLM output that drifted too far from the text it was asked to clean.
///
/// Both texts are reduced to lowercased word tokens without punctuation, so punctuation and casing fixes
/// cost nothing. The rule, in order:
///
/// 1. **Number class.** A run of spoken number words (English and German, compounds such as
///    "fünfundzwanzig", ordinals, "and"/"und"/"point"/"komma" between numbers) or digit tokens is one
///    token, so "twenty one" and "21", "three thirty" and "3:30", "zwölf … fünfzig" and "12,50" align.
///    Only the shape is compared, never the value. Chinese and Japanese text is tokenized by character.
/// 2. **Drift.** The word-level edit distance may be at most ``maxDrift`` of the longer token count, or one
///    token, whichever is more (a unit word that turned into a symbol, "euros" into "€", is one edit in a
///    two-token text). A spelling fix, a written form or a misrecognition replaces a word or two and stays
///    under the limit; an added sentence, an answer or a translation does not.
/// 3. **Dropped content.** Drift alone lets one dropped sentence through a long text (one in five is
///    under 25 %). So the candidate is also rejected when
///    - the reference holds two or more sentences (cut at `.`, `!`, `?` and their CJK forms) and the
///      candidate holds fewer, or
///    - four or more reference tokens in a row have no counterpart in the candidate
///      (``maxUnmatchedRun`` is 3).
///
/// With a ``wordRatio`` (the message style, ``message``) the rule is only that: the candidate's token
/// count, numbers counted as one, must lie within that multiple of the reference's. A message rewrite drops
/// fillers and false starts and applies spoken corrections, which the drift rule would reject.
public struct CleanupGuard: Sendable {
    /// The limit tuned against the cleanup fixtures and the literal pairs in `CleanupStageTests`.
    public static let defaultMaxDrift = 0.25

    /// The longest stretch of reference tokens that may go unmatched; one more means a dropped clause.
    public static let maxUnmatchedRun = 3

    /// Candidates with a drift above this are rejected.
    public var maxDrift: Double
    /// When set, replaces the drift rules: the candidate's token count over the reference's must lie in this
    /// range (bounds included).
    public var wordRatio: ClosedRange<Double>?

    public init(maxDrift: Double = CleanupGuard.defaultMaxDrift, wordRatio: ClosedRange<Double>? = nil) {
        self.maxDrift = maxDrift
        self.wordRatio = wordRatio
    }

    /// The looser guard of the message style: 0.4 to 1.3 times the input's words.
    public static let message = CleanupGuard(wordRatio: 0.4 ... 1.3)

    // MARK: tokens

    /// Lowercased runs of letters and digits; every Chinese or Japanese character is a token of its own.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for character in text.lowercased() {
            if isCJK(character) {
                flush()
                tokens.append(String(character))
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// The token that stands for every run of numbers in ``canonicalTokens(_:)``.
    static let numberToken = "#"

    /// ``tokens(_:)`` with each run of number words and digits collapsed into ``numberToken``.
    static func canonicalTokens(_ text: String) -> [String] {
        let raw = tokens(text)
        var out: [String] = []
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if Numbers.isNumber(token) {
                // Swallow the run: more numbers, and a connective only when a number follows it.
                var end = index + 1
                while end < raw.count {
                    if Numbers.isNumber(raw[end]) {
                        end += 1
                    } else if Numbers.connectives.contains(raw[end]), end + 1 < raw.count, Numbers.isNumber(raw[end + 1]) {
                        end += 2
                    } else {
                        break
                    }
                }
                out.append(numberToken)
                index = end
            } else {
                out.append(token)
                index += 1
            }
        }
        return out
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040 ... 0x30FF,  // hiragana, katakana
                 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF,  // han
                 0x20000 ... 0x2FA1F:
                true
            default:
                false
            }
        }
    }

    // MARK: sentences

    /// The number of sentences in `text`. A `.`, `!` or `?` ends one when whitespace or the end follows
    /// (so "3.5" does not); the CJK marks end one wherever they stand. Text after the last mark is one more.
    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var pendingText = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if "。！？".contains(character) {
                if pendingText { count += 1 }
                pendingText = false
            } else if ".!?…".contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if next == nil || next!.isWhitespace || "\"'”’)»".contains(next!) {
                    if pendingText { count += 1 }
                    pendingText = false
                }
            } else if character.isLetter || character.isNumber {
                pendingText = true
            }
            index += 1
        }
        return count + (pendingText ? 1 : 0)
    }

    // MARK: judging

    /// Word-level edit distance over the longer token count, in `0...1`.
    public func drift(candidate: String, reference: String) -> Double {
        let a = Self.canonicalTokens(reference)
        let b = Self.canonicalTokens(candidate)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return Double(Self.align(a, b).distance) / Double(longest)
    }

    /// Whether `candidate` is a faithful cleanup of `reference`.
    public func accepts(_ candidate: String, reference: String) -> Bool {
        let a = Self.canonicalTokens(reference)
        let b = Self.canonicalTokens(candidate)
        if b.isEmpty { return a.isEmpty }
        if let wordRatio {
            guard !a.isEmpty else { return false }
            return wordRatio.contains(Double(b.count) / Double(a.count))
        }
        let alignment = Self.align(a, b)
        let allowed = max(maxDrift * Double(max(a.count, b.count)), 1)
        guard Double(alignment.distance) <= allowed else { return false }
        if alignment.longestUnmatchedRun > Self.maxUnmatchedRun { return false }
        let referenceSentences = Self.sentenceCount(reference)
        return referenceSentences < 2 || Self.sentenceCount(candidate) >= referenceSentences
    }

    // MARK: alignment

    private struct Alignment {
        var distance: Int
        /// The longest stretch of reference tokens that are substituted or deleted without a match between.
        var longestUnmatchedRun: Int
    }

    private static func align(_ a: [String], _ b: [String]) -> Alignment {
        if a.isEmpty { return Alignment(distance: b.count, longestUnmatchedRun: 0) }
        if b.isEmpty { return Alignment(distance: a.count, longestUnmatchedRun: a.count) }
        let width = b.count + 1
        var table = [Int](repeating: 0, count: (a.count + 1) * width)
        for j in 0 ... b.count { table[j] = j }
        for i in 1 ... a.count {
            table[i * width] = i
            for j in 1 ... b.count {
                let substitution = table[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                table[i * width + j] = min(substitution, table[(i - 1) * width + j] + 1, table[i * width + j - 1] + 1)
            }
        }
        // Walk back from the end, preferring a match, then a substitution, then a deletion.
        var i = a.count
        var j = b.count
        var run = 0
        var longest = 0
        while i > 0 || j > 0 {
            let here = table[i * width + j]
            if i > 0, j > 0, a[i - 1] == b[j - 1], table[(i - 1) * width + j - 1] == here {
                i -= 1
                j -= 1
                run = 0
            } else if i > 0, j > 0, table[(i - 1) * width + j - 1] + 1 == here {
                i -= 1
                j -= 1
                run += 1
            } else if i > 0, table[(i - 1) * width + j] + 1 == here {
                i -= 1
                run += 1
            } else {
                j -= 1  // an insertion neither extends nor ends a run
            }
            longest = max(longest, run)
        }
        return Alignment(distance: table[a.count * width + b.count], longestUnmatchedRun: longest)
    }
}

/// Spoken number words in English and German.
private enum Numbers {
    /// Words that join two numbers into one ("one hundred and five", "zwei und zwanzig", "three point five").
    static let connectives: Set<String> = ["and", "und", "point", "komma"]

    static func isNumber(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        if first.isNumber { return true }  // "12", "3rd", "10am"
        return english.contains(token) || german(token)
    }

    private static let english: Set<String> = {
        let cardinals = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
            "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        ]
        let ordinals = [
            "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
            "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
            "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
            "hundredth", "thousandth", "millionth",
        ]
        return Set(cardinals + ordinals)
    }()

    /// The pieces German number words are built from ("fünfundzwanzig" is fünf + und + zwanzig).
    private static let germanAtoms: [String] = [
        "null", "eins", "ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf",
        "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn", "zwanzig", "dreißig",
        "dreissig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig", "hundert", "tausend",
        "million", "millionen", "milliarde", "milliarden", "und",
    ]

    /// Ordinal stems that are not a cardinal plus "t" or "st".
    private static let germanOrdinalStems: Set<String> = ["erst", "dritt", "siebt"]

    private static let germanEndings = ["", "e", "en", "er", "es", "em"]

    /// A cardinal ("zwölf", "fünfundzwanzig"), possibly declined ("eine"), or an ordinal ("zweiten",
    /// "zwanzigsten", "dritte").
    private static func german(_ token: String) -> Bool {
        for ending in germanEndings where token.hasSuffix(ending) {
            let stem = String(token.dropLast(ending.count))
            if stem.isEmpty { continue }
            if segmentsIntoAtoms(stem) || germanOrdinalStems.contains(stem) { return true }
            if stem.hasSuffix("st"), segmentsIntoAtoms(String(stem.dropLast(2))) { return true }
            if stem.hasSuffix("t"), segmentsIntoAtoms(String(stem.dropLast(1))) { return true }
        }
        return false
    }

    /// Whether `word` is made of German number atoms only, with at least one that is not "und".
    private static func segmentsIntoAtoms(_ word: String) -> Bool {
        let characters = Array(word)
        guard !characters.isEmpty else { return false }
        // reachable[i]: the first i characters split into atoms; realAtom[i]: one of them is not "und".
        var reachable = [Bool](repeating: false, count: characters.count + 1)
        var real = [Bool](repeating: false, count: characters.count + 1)
        reachable[0] = true
        for start in 0 ..< characters.count where reachable[start] {
            for atom in germanAtoms {
                let length = atom.count
                guard start + length <= characters.count,
                      String(characters[start ..< start + length]) == atom
                else { continue }
                reachable[start + length] = true
                if atom != "und" || real[start] { real[start + length] = true }
            }
        }
        return reachable[characters.count] && real[characters.count]
    }
}
