import Foundation
import LegatoCore
import LegatoPostProcessing
import Tokenizers

// Spike #95: the continuous cleanup-agent workload, shared by the phone's session probe (internal builds) and
// the Mac runner (`spikes/continuous-agent`). The annotated corpus (ContinuousAgentCorpus.swift) streams in
// 5–15-word chunks at speech pace into one warm session; after each chunk the model answers "no edit" (`[]`)
// or one edit (`{"sentence":n,"text":"…"}`). The headline number is mistake-to-fix latency: from the moment the
// ASR delivered the chunk that completes a mistake (local) or ends its sentence (sentence rewrite) until the
// turn that fixes it returns, on one clock (stream time at speech pace plus real model time, backlog included).
// Backend-agnostic: the host builds the backend and samples memory, battery and thermal state itself.

// MARK: - Corpus model

public enum ProbeMistakeKind: String, Sendable, Hashable, CaseIterable {
    /// Fixable as soon as the wrong span is written.
    case local
    /// Needs the whole sentence.
    case sentence
}

public struct ProbeMistake: Sendable, Hashable {
    public var wrong: String
    /// One of these must appear once `wrong` is gone; empty: removing `wrong` is the fix.
    public var fixes: [String]
    public var kind: ProbeMistakeKind
    /// spelling, homophone, boundary, casing, punctuation, artefact, repetition, filler, number, url, email, …
    public var type: String
    public init(wrong: String, fixes: [String], kind: ProbeMistakeKind, type: String) {
        self.wrong = wrong; self.fixes = fixes; self.kind = kind; self.type = type
    }

    public func isFixed(in text: String) -> Bool {
        !ProbeText.contains(text, wrong) && (fixes.isEmpty || fixes.contains { ProbeText.contains(text, $0) })
    }
}

public struct ProbeSentence: Sendable, Hashable {
    public var id: String
    public var passage: String
    public var tags: [String]
    /// The raw dictation, as the ASR wrote it.
    public var text: String
    /// The clean text (every mistake fixed).
    public var reference: String
    public var mistakes: [ProbeMistake]
    public init(id: String, passage: String, tags: [String], text: String, reference: String, mistakes: [ProbeMistake]) {
        self.id = id; self.passage = passage; self.tags = tags; self.text = text; self.reference = reference; self.mistakes = mistakes
    }
}

public enum ProbeCorpus {
    public static var wordCount: Int { sentences.reduce(0) { $0 + ProbeChunker.words($1.text).count } }
    public static var mistakeCount: Int { sentences.reduce(0) { $0 + $1.mistakes.count } }
}

/// Case-sensitive phrase matching on word boundaries (no letter, digit or `#` right before or after the match).
public enum ProbeText {
    public static func ranges(_ text: String, _ phrase: String) -> [Range<String.Index>] {
        guard !phrase.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: phrase, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { found.append(range) }
            start = text.index(after: range.lowerBound)
        }
        return found
    }

    public static func contains(_ text: String, _ phrase: String) -> Bool { !ranges(text, phrase).isEmpty }

    /// The 0-based index of the whitespace-separated word that holds the end of the first match of `phrase`.
    public static func endWordIndex(of phrase: String, in text: String) -> Int? {
        guard let range = ranges(text, phrase).first else { return nil }
        return ProbeChunker.words(String(text[..<range.upperBound])).count - 1
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "#"  // "#um" is one token
    }
}

// MARK: - Stream

public struct ProbeWord: Sendable, Hashable {
    public var text: String
    /// The stream sentence (1-based, local to the run) it belongs to.
    public var sentence: Int
}

/// One piece of the stream: the words that arrive together.
public struct ProbeChunk: Sendable, Hashable {
    public var index: Int
    public var words: [ProbeWord]
    /// The stream position of the first word.
    public var firstWord: Int
    /// Seconds from the stream's start until this chunk has been spoken (its last word).
    public var dueSeconds: Double
    /// How long this chunk takes to say: the time a turn has to keep up.
    public var speechSeconds: Double
    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// Cuts the stream into chunks of `minWords`…`maxWords` (seeded; the last chunk may be shorter).
public enum ProbeChunker {
    public static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    public static func chunks(sentences: [ProbeSentence], wordsPerSecond: Double, seed: UInt64,
                              minWords: Int = 5, maxWords: Int = 15) -> [ProbeChunk] {
        let stream = sentences.enumerated().flatMap { offset, sentence in
            words(sentence.text).map { ProbeWord(text: $0, sentence: offset + 1) }
        }
        var random = SplitMix64(seed: seed)
        var chunks: [ProbeChunk] = []
        var position = 0
        let low = max(1, minWords), high = max(low, maxWords)
        while position < stream.count {
            let end = min(stream.count, position + low + Int(random.next() % UInt64(high - low + 1)))
            chunks.append(ProbeChunk(index: chunks.count, words: Array(stream[position..<end]), firstWord: position,
                                     dueSeconds: Double(end) / wordsPerSecond, speechSeconds: Double(end - position) / wordsPerSecond))
            position = end
        }
        return chunks
    }

    /// For each sentence (0-based) and mistake, the chunk from which its latency counts: the chunk with the
    /// wrong span's last word (local) or the sentence's last word (sentence). Nil when the span is not found.
    public static func appearance(sentences: [ProbeSentence], chunks: [ProbeChunk]) -> [[Int?]] {
        var chunkOfWord: [Int] = []
        for chunk in chunks { chunkOfWord += Array(repeating: chunk.index, count: chunk.words.count) }
        var start = 0
        return sentences.map { sentence in
            defer { start += words(sentence.text).count }
            let last = words(sentence.text).count - 1
            return sentence.mistakes.map { mistake in
                let index = mistake.kind == .local ? ProbeText.endWordIndex(of: mistake.wrong, in: sentence.text) : last
                return index.flatMap { chunkOfWord.indices.contains(start + $0) ? chunkOfWord[start + $0] : nil }
            }
        }
    }
}

/// A small deterministic generator (SplitMix64).
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Shadow document

/// Each stream sentence's words so far, with the agent's edits applied. Numbers start after `numberOffset`
/// (a warm continuation keeps numbering past the previous run's sentences, which its session still holds).
public struct ProbeDocument: Sendable {
    public struct Entry: Sendable, Hashable {
        public var source: ProbeSentence
        public var received: [String] = []
        public var total: Int
        /// The text after the agent's last edit, or nil while unedited.
        public var edited: String?
        public var finished: Bool { received.count >= total }
        public var text: String { edited ?? received.joined(separator: " ") }
    }

    public private(set) var entries: [Entry]
    public let numberOffset: Int

    public init(sentences: [ProbeSentence], numberOffset: Int = 0) {
        entries = sentences.map { Entry(source: $0, total: ProbeChunker.words($0.text).count) }
        self.numberOffset = numberOffset
    }

    /// Adds the chunk's words; returns the sentence numbers (as the model sees them) it touched, in order.
    public mutating func receive(_ chunk: ProbeChunk) -> [Int] {
        var touched: [Int] = []
        for word in chunk.words {
            entries[word.sentence - 1].received.append(word.text)
            if touched.last != word.sentence + numberOffset { touched.append(word.sentence + numberOffset) }
        }
        return touched
    }

    /// The 0-based entry index of a model-facing number, when that sentence has started.
    public func index(of number: Int) -> Int? {
        let index = number - numberOffset - 1
        return entries.indices.contains(index) && !entries[index].received.isEmpty ? index : nil
    }

    public func entry(_ number: Int) -> Entry? { index(of: number).map { entries[$0] } }

    public mutating func setText(_ text: String, at index: Int) { entries[index].edited = text }

    /// The user turn for one chunk: the touched sentences numbered, the finished ones to review.
    public func request(touched: [Int]) -> String {
        var lines = ["<sentences>"]
        lines += touched.compactMap { number in entry(number).map { "\(number). \($0.text)" } }
        lines.append("</sentences>")
        let review = touched.filter { entry($0)?.finished == true }
        lines.append("Review: \(review.isEmpty ? "none" : review.map(String.init).joined(separator: ", ")).")
        lines.append(#"Reply [] or one edit {"sentence":n,"text":"…"}."#)
        return lines.joined(separator: "\n")
    }
}

/// What one edit did to its sentence's mistakes.
public struct ProbeEditEffect: Sendable, Hashable {
    /// Indices into the sentence's mistakes that this edit fixed.
    public var fixed: [Int]
    /// Indices of mistakes fixed earlier that this edit brought back.
    public var regressed: [Int]
    /// The text did not change.
    public var noop: Bool
    /// A change that fixed nothing (changed correct text, or did not match an acceptable fix).
    public var wrong: Bool

    public static func evaluate(before: String, after: String, mistakes: [ProbeMistake], fixedBefore: [Bool]) -> ProbeEditEffect {
        var fixed: [Int] = [], regressed: [Int] = []
        for (index, mistake) in mistakes.enumerated() {
            let now = mistake.isFixed(in: after)
            if now, !fixedBefore[index] { fixed.append(index) }
            if !now, fixedBefore[index] { regressed.append(index) }
        }
        let noop = ProbeChunker.words(before) == ProbeChunker.words(after)
        return ProbeEditEffect(fixed: fixed, regressed: regressed, noop: noop, wrong: !noop && fixed.isEmpty)
    }
}

/// The session head for the continuous agent: the live agent's message-style instructions (fixes, filler,
/// false starts and self-corrections), narrowed to one edit per turn.
public enum ProbeInstructions {
    public static func head(locale: Locale = Locale(identifier: "en_US")) -> String {
        CleanupPrompt.Agent.instructions(locale: locale, style: .message) + "\n" + #"""
        The text arrives in pieces while the user speaks. Each request lists the sentences the newest piece touched; earlier sentences are in the conversation above. Answer with exactly one JSON value and nothing else: [] when no sentence under "Review" needs a change, or {"sentence": n, "text": "the full corrected sentence"} for the single most needed change.
        """#
    }
}

// MARK: - Replies

/// A reply, read leniently enough to measure (the contract is `[]` or one object; an array of objects is
/// accepted and flagged).
public enum ProbeReply: Sendable, Hashable {
    case noEdit
    case edits([SentenceEdit], exact: Bool)
    case invalid(String)

    public var parseOK: Bool { if case .invalid = self { false } else { true } }
    public var edits: [SentenceEdit] { if case .edits(let edits, _) = self { edits } else { [] } }

    public static func parse(_ raw: String) -> ProbeReply {
        var text = raw
        // A stray (empty) think block, as Qwen3 emits with thinking off.
        while let open = text.range(of: "<think>") {
            guard let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
                return .invalid("unterminated think block")
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() } else { return .invalid("unterminated fence") }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8), !text.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .invalid("not JSON")
        }
        if let array = value as? [Any] {
            if array.isEmpty { return .noEdit }
            var edits: [SentenceEdit] = []
            for item in array {
                guard let edit = edit(item) else { return .invalid("array item is not {sentence, text}") }
                edits.append(edit)
            }
            return .edits(edits, exact: false)  // the contract is a bare object
        }
        if let edit = edit(value) { return .edits([edit], exact: true) }
        return .invalid("not [] or {sentence, text}")
    }

    private static func edit(_ value: Any) -> SentenceEdit? {
        guard let object = value as? [String: Any], object.count == 2,
              let number = object["sentence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), let text = object["text"] as? String else { return nil }
        return SentenceEdit(sentence: number.intValue, text: text)
    }
}

// MARK: - Statistics

public enum ProbeStats {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Nearest-rank percentile (`p` in 0…100).
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count, max(1, rank)) - 1]
    }

    public static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (n − 1); nil below two values.
    public static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let mean = mean(values) else { return nil }
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)).squareRoot()
    }

    /// Percent of `flags` that are true (0 when empty).
    public static func percent(_ flags: [Bool]) -> Double {
        flags.isEmpty ? 0 : Double(flags.filter { $0 }.count) * 100 / Double(flags.count)
    }

    /// `prefix` + mean/median/p95/sd (rounded ms) of `values`, plus the count.
    public static func describe(_ values: [Double], _ prefix: String) -> [String: any Sendable] {
        var fields: [String: any Sendable] = ["\(prefix)N": values.count]
        if let v = mean(values) { fields["\(prefix)Mean"] = Int(v.rounded()) }
        if let v = median(values) { fields["\(prefix)Median"] = Int(v.rounded()) }
        if let v = percentile(values, 95) { fields["\(prefix)P95"] = Int(v.rounded()) }
        if let v = standardDeviation(values) { fields["\(prefix)Sd"] = Int(v.rounded()) }
        return fields
    }

    static func ratio(_ k: Int, _ n: Int) -> String { "\(k)/\(n)" }
}

// MARK: - Records

/// One chunk's turn, as logged.
public struct ProbeTurnRecord: Sendable {
    public var rep: Int
    public var phase: String
    public var chunk: Int
    public var words: Int
    public var speechMs: Int
    /// How late the turn started after its chunk was spoken (a backlog from slower turns).
    public var lagMs: Int
    public var promptTokens: Int?
    public var prefillTokens: Int?
    public var prefillMs: Int?
    public var ttftMs: Int?
    /// `stream` (the first generated chunk, MLX) or `prefill` (the end of prefill: Core ML has no token stream).
    public var ttftSource: String = "prefill"
    public var decodeTokens: Int?
    public var decodeMs: Int?
    public var totalMs: Int = 0
    public var keptUp = false
    public var reply = ""
    public var parseOK = false
    public var parseNote: String?
    public var edits = 0
    public var editsApplied = 0
    public var wrongEdits = 0
    /// Mistakes this turn fixed (sentence id + wrong span).
    public var fixed: [String] = []
    public var error: String?
    public var trimmed = false
    public var contextTokens: Int?

    public init(rep: Int, phase: String, chunk: Int, words: Int, speechMs: Int, lagMs: Int) {
        self.rep = rep; self.phase = phase; self.chunk = chunk; self.words = words; self.speechMs = speechMs; self.lagMs = lagMs
    }

    public var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "rep": rep, "phase": phase, "chunk": chunk, "words": words, "speechMs": speechMs, "lagMs": lagMs,
            "ttftSource": ttftSource, "totalMs": totalMs, "keptUp": keptUp, "reply": String(reply.prefix(400)),
            "parseOk": parseOK, "edits": edits, "editsApplied": editsApplied, "wrongEdits": wrongEdits,
            "fixed": fixed.joined(separator: "|"), "trimmed": trimmed,
        ]
        if let promptTokens { fields["promptTokens"] = promptTokens }
        if let prefillTokens { fields["prefillTokens"] = prefillTokens }
        if let prefillMs { fields["prefillMs"] = prefillMs }
        if let ttftMs { fields["ttftMs"] = ttftMs }
        if let decodeTokens { fields["decodeTokens"] = decodeTokens }
        if let decodeMs { fields["decodeMs"] = decodeMs }
        if let parseNote { fields["parseNote"] = parseNote }
        if let error { fields["error"] = error }
        if let contextTokens { fields["contextTokens"] = contextTokens }
        return fields
    }
}

/// What became of one annotated mistake in one run.
public struct ProbeMistakeOutcome: Sendable {
    public var rep: Int
    public var phase: String
    public var sentence: String
    public var passage: String
    public var tags: [String]
    public var mistake: ProbeMistake
    public var appearChunk: Int?
    /// Stream seconds when the ASR delivered the appearance chunk.
    public var appearSeconds: Double?
    public var fixedChunk: Int?
    /// Run-clock seconds when the fixing turn returned.
    public var fixedSeconds: Double?
    public var regressed = false

    public var latencyMs: Int? {
        guard let appearSeconds, let fixedSeconds else { return nil }
        return Int(((fixedSeconds - appearSeconds) * 1_000).rounded())
    }
    /// Chunks from appearance to the fixing turn (0: fixed in the turn of the appearance chunk).
    public var chunksToFix: Int? { fixedChunk.flatMap { f in appearChunk.map { f - $0 } } }

    public var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "rep": rep, "phase": phase, "sentence": sentence, "passage": passage, "tags": tags.joined(separator: ","),
            "kind": mistake.kind.rawValue, "type": mistake.type, "wrong": mistake.wrong, "fixedOk": fixedChunk != nil,
            "regressed": regressed,
        ]
        if let appearChunk { fields["appearChunk"] = appearChunk }
        if let fixedChunk { fields["fixedChunk"] = fixedChunk }
        if let latencyMs { fields["latencyMs"] = latencyMs }
        if let chunksToFix { fields["chunksToFix"] = chunksToFix }
        return fields
    }
}

/// One edit the model asked for.
public struct ProbeEditOutcome: Sendable {
    public var rep: Int
    public var chunk: Int
    public var passage: String?
    public var tags: [String]
    public var applied: Bool
    public var wrong: Bool
    public var noop: Bool
}

public struct ProbeRunResult: Sendable {
    public var rep: Int
    public var phase: String
    public var records: [ProbeTurnRecord]
    public var mistakes: [ProbeMistakeOutcome]
    public var edits: [ProbeEditOutcome]
    public var wallSeconds: Double
}

/// Mistake and edit figures over any set of outcomes (one run, all fresh runs, one tag…).
public struct ProbeQuality: Sendable {
    public var mistakes: [ProbeMistakeOutcome]
    public var edits: [ProbeEditOutcome]
    /// "Fixed within N chunks" counts fixes at most this many chunks after the appearance chunk.
    public static let withinChunks = 2

    public init(mistakes: [ProbeMistakeOutcome], edits: [ProbeEditOutcome]) { self.mistakes = mistakes; self.edits = edits }

    public var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = [:]
        for kind in ProbeMistakeKind.allCases {
            let group = mistakes.filter { $0.mistake.kind == kind }
            let fixed = group.filter { $0.fixedChunk != nil }
            let within = fixed.filter { ($0.chunksToFix ?? .max) <= Self.withinChunks }
            fields["\(kind.rawValue)Fixed"] = ProbeStats.ratio(fixed.count, group.count)
            fields["\(kind.rawValue)FixedWithin\(Self.withinChunks)"] = ProbeStats.ratio(within.count, group.count)
            if !group.isEmpty { fields["\(kind.rawValue)FixedPct"] = ((Double(fixed.count) * 1_000 / Double(group.count)).rounded()) / 10 }
            fields.merge(ProbeStats.describe(fixed.compactMap { $0.latencyMs.map(Double.init) }, "\(kind.rawValue)LatencyMs")) { $1 }
        }
        let all = mistakes.filter { $0.fixedChunk != nil }
        fields["fixed"] = ProbeStats.ratio(all.count, mistakes.count)
        fields["regressed"] = mistakes.filter(\.regressed).count
        let changed = edits.filter { !$0.noop }
        fields["wrongEdits"] = ProbeStats.ratio(edits.filter(\.wrong).count, edits.count)
        fields["noopEdits"] = edits.filter(\.noop).count
        fields["changingEdits"] = changed.count
        if !edits.isEmpty { fields["wrongEditPct"] = ((Double(edits.filter(\.wrong).count) * 1_000 / Double(edits.count)).rounded()) / 10 }
        return fields
    }
}

/// Per-run and pooled figures.
public enum ProbeReport {
    public static func compute(_ records: [ProbeTurnRecord]) -> [String: any Sendable] {
        let ok = records.filter { $0.error == nil }
        var fields = ProbeStats.describe(ok.map { Double($0.totalMs) }, "turnMs")
        fields.merge(ProbeStats.describe(ok.compactMap { $0.prefillMs.map(Double.init) }, "prefillMs")) { $1 }
        fields.merge(ProbeStats.describe(ok.compactMap { $0.ttftMs.map(Double.init) }, "ttftMs")) { $1 }
        let rates = ok.compactMap { record -> Double? in
            guard let tokens = record.decodeTokens, let ms = record.decodeMs, ms > 0, tokens > 1 else { return nil }
            return Double(tokens) * 1_000 / Double(ms)
        }
        if let median = ProbeStats.median(rates) { fields["decodeTokPerSMedian"] = (median * 10).rounded() / 10 }
        fields["chunks"] = records.count
        fields["turnsFailed"] = records.count - ok.count
        fields["keepUp"] = ProbeStats.ratio(records.filter(\.keptUp).count, records.count)
        fields["keepUpPct"] = (ProbeStats.percent(records.map(\.keptUp)) * 10).rounded() / 10
        fields["maxLagMs"] = records.map(\.lagMs).max() ?? 0
        fields["parseOk"] = ProbeStats.ratio(records.filter(\.parseOK).count, records.count)
        fields["trims"] = records.filter(\.trimmed).count
        return fields
    }

    public static func run(_ result: ProbeRunResult) -> [String: any Sendable] {
        var fields = compute(result.records).merging(ProbeQuality(mistakes: result.mistakes, edits: result.edits).fields) { $1 }
        fields["rep"] = result.rep; fields["phase"] = result.phase
        fields["wallS"] = (result.wallSeconds * 10).rounded() / 10
        return fields
    }

    /// The fresh runs pooled (`phase` "fresh"; the warm continuation is its own row), or all when none is fresh.
    public static func pooled(_ results: [ProbeRunResult], phase: String = "fresh") -> [String: any Sendable] {
        let chosen = results.filter { $0.phase == phase }
        var fields = compute(chosen.flatMap(\.records))
            .merging(ProbeQuality(mistakes: chosen.flatMap(\.mistakes), edits: chosen.flatMap(\.edits)).fields) { $1 }
        fields["runs"] = chosen.count; fields["phase"] = phase
        // Spread of the per-run medians: how much one run differs from the next.
        let local = chosen.compactMap { run in ProbeStats.median(run.mistakes.filter { $0.mistake.kind == .local }.compactMap { $0.latencyMs.map(Double.init) }) }
        if let sd = ProbeStats.standardDeviation(local) { fields["localLatencyRunMedianSd"] = Int(sd.rounded()) }
        return fields
    }

    /// Quality per tag (passage tags), per mistake type and per passage, over the runs of `phase`.
    public static func breakdown(_ results: [ProbeRunResult], phase: String = "fresh") -> [(group: String, fields: [String: any Sendable])] {
        let chosen = results.filter { $0.phase == phase }
        let mistakes = chosen.flatMap(\.mistakes), edits = chosen.flatMap(\.edits)
        var keys: [String] = []
        for m in mistakes {
            for key in m.tags.map({ "tag:\($0)" }) + ["type:\(m.mistake.type)", "passage:\(m.passage)"] where !keys.contains(key) { keys.append(key) }
        }
        return keys.sorted().map { key in
            let (dimension, value) = (key.split(separator: ":", maxSplits: 1).map(String.init)[0], String(key.drop { $0 != ":" }.dropFirst()))
            let m: [ProbeMistakeOutcome], e: [ProbeEditOutcome]
            switch dimension {
            case "tag": m = mistakes.filter { $0.tags.contains(value) }; e = edits.filter { $0.tags.contains(value) }
            case "type": m = mistakes.filter { $0.mistake.type == value }; e = []
            default: m = mistakes.filter { $0.passage == value }; e = edits.filter { $0.passage == value }
            }
            var fields = ProbeQuality(mistakes: m, edits: e).fields
            fields["group"] = key; fields["phase"] = phase
            return (key, fields)
        }
    }
}

// MARK: - Run

public struct ProbeConfig: Sendable {
    public var wordsPerSecond: Double
    /// Fresh-session runs of the whole stream; each uses `seed + rep - 1` for its chunk boundaries.
    public var repeats: Int
    /// After the fresh runs, one more pass of the stream on the last run's session (numbering continued).
    public var warmContinuation: Bool
    public var seed: UInt64
    /// The context the run keeps (tokens): trimmed to a third once past three quarters. The same for every
    /// backend (Core ML 1.7B's session budget is about 1,000), capped by the session's own budget.
    public var window: Int
    /// Chunk sizes, in words.
    public var minWords = 5
    public var maxWords = 15

    public init(wordsPerSecond: Double = 2.5, repeats: Int = 3, warmContinuation: Bool = true, seed: UInt64 = 95, window: Int = 1_000) {
        self.wordsPerSecond = wordsPerSecond; self.repeats = repeats; self.warmContinuation = warmContinuation
        self.seed = seed; self.window = window
    }

    /// From `LEGATO_PROBE_WPS`, `LEGATO_PROBE_REPEATS`, `LEGATO_PROBE_WARM` (1/0), `LEGATO_PROBE_SEED`,
    /// `LEGATO_PROBE_WINDOW`.
    public init(environment: [String: String], defaultRepeats: Int = 3, defaultWarm: Bool = true) {
        let defaults = ProbeConfig(repeats: defaultRepeats, warmContinuation: defaultWarm)
        self.init(wordsPerSecond: environment["LEGATO_PROBE_WPS"].flatMap(Double.init) ?? defaults.wordsPerSecond,
                  repeats: max(1, environment["LEGATO_PROBE_REPEATS"].flatMap(Int.init) ?? defaults.repeats),
                  warmContinuation: environment["LEGATO_PROBE_WARM"].map { $0 != "0" } ?? defaults.warmContinuation,
                  seed: environment["LEGATO_PROBE_SEED"].flatMap(UInt64.init) ?? defaults.seed,
                  window: environment["LEGATO_PROBE_WINDOW"].flatMap(Int.init) ?? defaults.window)
    }

    /// Stream seconds of one pass at this pace.
    public func streamSeconds(_ corpus: [ProbeSentence] = ProbeCorpus.sentences) -> Double {
        Double(corpus.reduce(0) { $0 + ProbeChunker.words($1.text).count }) / wordsPerSecond
    }
}

/// Replays the stream into warm sessions at speech pace.
public enum ContinuousAgentProbe {
    public struct Hooks: Sendable {
        /// Tokens in a reply (the model's tokenizer), nil when unknown.
        public var countTokens: @Sendable (String) async -> Int?
        public var onTurn: @Sendable (ProbeTurnRecord) async -> Void
        /// Lines that are not turns: `warm`, `trim`, `stop`, `mistake`, `run`.
        public var onEvent: @Sendable (String, [String: any Sendable]) async -> Void
        public init(countTokens: @escaping @Sendable (String) async -> Int?,
                    onTurn: @escaping @Sendable (ProbeTurnRecord) async -> Void,
                    onEvent: @escaping @Sendable (String, [String: any Sendable]) async -> Void) {
            self.countTokens = countTokens; self.onTurn = onTurn; self.onEvent = onEvent
        }
    }

    /// The fresh runs, then the warm continuation. A run that cannot open its session is logged and skipped.
    public static func runAll(backend: any LLMBackend, config: ProbeConfig, hooks: Hooks,
                              corpus: [ProbeSentence] = ProbeCorpus.sentences) async -> [ProbeRunResult] {
        var results: [ProbeRunResult] = []
        var kept: (session: any LLMSession, context: Int?)?
        for rep in 1...max(1, config.repeats) {
            do {
                let session = try await open(backend, hooks: hooks, rep: rep)
                let (result, context) = await replay(session: session, corpus: corpus, config: config, rep: rep, phase: "fresh",
                                                     seed: config.seed &+ UInt64(rep - 1), numberOffset: 0, context: nil, hooks: hooks)
                results.append(result)
                await hooks.onEvent("run", ProbeReport.run(result))
                if rep == config.repeats, config.warmContinuation { kept = (session, context) } else { await session.close() }
            } catch {
                await hooks.onEvent("stop", ["rep": rep, "reason": "session failed: \(error)"])
            }
        }
        if let kept {
            let rep = config.repeats + 1
            let (result, _) = await replay(session: kept.session, corpus: corpus, config: config, rep: rep, phase: "warm",
                                           seed: config.seed &+ UInt64(config.repeats), numberOffset: corpus.count,
                                           context: kept.context, hooks: hooks)
            results.append(result)
            await hooks.onEvent("run", ProbeReport.run(result))
            await kept.session.close()
        }
        return results
    }

    private static func open(_ backend: any LLMBackend, hooks: Hooks, rep: Int) async throws -> any LLMSession {
        let session = try await backend.makeSession()
        try await session.append(.instructions(ProbeInstructions.head()))
        let clock = ContinuousClock()
        let start = clock.now
        try await session.warm()
        var fields: [String: any Sendable] = ["rep": rep, "wallMs": ms(clock.now - start), "tokenBudget": session.tokenBudget]
        if let tokens = await (session as? any LLMSessionMetrics)?.lastWarmMetrics()?.prefilledTokens { fields["prefillTokens"] = tokens }
        await hooks.onEvent("warm", fields)
        return session
    }

    /// One pass of the stream on `session`. Three failures in a row or a closed session end it early.
    static func replay(session: any LLMSession, corpus: [ProbeSentence], config: ProbeConfig, rep: Int, phase: String,
                       seed: UInt64, numberOffset: Int, context: Int?, hooks: Hooks) async -> (ProbeRunResult, Int?) {
        let chunks = ProbeChunker.chunks(sentences: corpus, wordsPerSecond: config.wordsPerSecond, seed: seed,
                                         minWords: config.minWords, maxWords: config.maxWords)
        let appearance = ProbeChunker.appearance(sentences: corpus, chunks: chunks)
        var outcomes: [[ProbeMistakeOutcome]] = corpus.enumerated().map { index, sentence in
            sentence.mistakes.enumerated().map { m, mistake in
                let chunk = appearance[index][m]
                return ProbeMistakeOutcome(rep: rep, phase: phase, sentence: sentence.id, passage: sentence.passage, tags: sentence.tags,
                                           mistake: mistake, appearChunk: chunk, appearSeconds: chunk.map { chunks[$0].dueSeconds })
            }
        }
        var document = ProbeDocument(sentences: corpus, numberOffset: numberOffset)
        var editOutcomes: [ProbeEditOutcome] = []
        let window = min(config.window, session.tokenBudget)
        var context = context
        var records: [ProbeTurnRecord] = []
        var failuresInARow = 0
        let clock = ContinuousClock()
        let start = clock.now
        func seconds(_ instant: ContinuousClock.Instant) -> Double { Double(ms(instant - start)) / 1_000 }

        for chunk in chunks {
            let due = start + .milliseconds(Int(chunk.dueSeconds * 1_000))
            if clock.now < due { try? await Task.sleep(until: due, clock: clock) }
            let touched = document.receive(chunk)
            var record = ProbeTurnRecord(rep: rep, phase: phase, chunk: chunk.index, words: chunk.words.count,
                                         speechMs: Int(chunk.speechSeconds * 1_000), lagMs: max(0, ms(clock.now - due)))
            if let tokens = context, tokens > window * 3 / 4 {
                do {
                    try await session.trim(keepingSuffix: window / 3)
                    record.trimmed = true
                    await hooks.onEvent("trim", ["rep": rep, "phase": phase, "chunk": chunk.index, "contextTokens": tokens, "keep": window / 3])
                } catch {
                    await hooks.onEvent("trim", ["rep": rep, "phase": phase, "chunk": chunk.index, "error": "\(error)"])
                }
            }
            let request = document.request(touched: touched)
            let turnStart = clock.now
            do {
                let reply = try await session.respond(to: request)
                let end = clock.now
                record.totalMs = ms(end - turnStart)
                record.keptUp = record.totalMs < record.speechMs
                record.reply = reply
                let metrics = await (session as? any LLMSessionMetrics)?.lastTurnMetrics()
                record.promptTokens = metrics?.promptTokens
                record.prefillTokens = metrics?.prefilledTokens
                record.prefillMs = metrics?.prefillSeconds.map { Int($0 * 1_000) }
                if let first = await MLXProbeSupport.firstChunkSeconds(session) {
                    record.ttftMs = Int(first * 1_000); record.ttftSource = "stream"
                } else {
                    record.ttftMs = record.prefillMs
                }
                record.decodeTokens = await hooks.countTokens(reply)
                record.decodeMs = record.ttftMs.map { max(0, record.totalMs - $0) }
                let parsed = ProbeReply.parse(reply)
                record.parseOK = parsed.parseOK
                switch parsed {
                case .invalid(let note): record.parseNote = note
                case .edits(let edits, let exact): if !exact { record.parseNote = "array of \(edits.count)" }
                case .noEdit: break
                }
                record.edits = parsed.edits.count
                for edit in parsed.edits {
                    guard let index = document.index(of: edit.sentence) else {
                        editOutcomes.append(ProbeEditOutcome(rep: rep, chunk: chunk.index, passage: nil, tags: [], applied: false, wrong: true, noop: false))
                        record.wrongEdits += 1
                        continue
                    }
                    let sentence = corpus[index]
                    let effect = ProbeEditEffect.evaluate(before: document.entries[index].text, after: edit.text, mistakes: sentence.mistakes,
                                                          fixedBefore: outcomes[index].map { $0.fixedChunk != nil })
                    document.setText(edit.text, at: index)
                    record.editsApplied += 1
                    if effect.wrong { record.wrongEdits += 1 }
                    for m in effect.fixed {
                        outcomes[index][m].fixedChunk = chunk.index
                        outcomes[index][m].fixedSeconds = seconds(end)
                        record.fixed.append("\(sentence.id):\(sentence.mistakes[m].wrong)")
                    }
                    for m in effect.regressed {  // undone: a later fix counts from its own turn
                        outcomes[index][m].regressed = true
                        outcomes[index][m].fixedChunk = nil; outcomes[index][m].fixedSeconds = nil
                    }
                    editOutcomes.append(ProbeEditOutcome(rep: rep, chunk: chunk.index, passage: sentence.passage, tags: sentence.tags,
                                                         applied: true, wrong: effect.wrong, noop: effect.noop))
                }
                if let prompt = record.promptTokens { context = prompt + (record.decodeTokens ?? 0) }
                failuresInARow = 0
            } catch {
                record.totalMs = ms(clock.now - turnStart)
                record.error = String(String(describing: error).prefix(300))
                failuresInARow += 1
            }
            record.contextTokens = context
            records.append(record)
            await hooks.onTurn(record)
            if let error = record.error, failuresInARow >= 3 || error.contains("closed") {
                await hooks.onEvent("stop", ["rep": rep, "phase": phase, "chunk": chunk.index,
                                             "reason": failuresInARow >= 3 ? "3 failures in a row" : "session closed"])
                break
            }
        }
        let flat = outcomes.flatMap { $0 }
        for outcome in flat { await hooks.onEvent("mistake", outcome.fields) }
        let result = ProbeRunResult(rep: rep, phase: phase, records: records, mistakes: flat, edits: editOutcomes,
                                    wallSeconds: seconds(clock.now))
        return (result, context)
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

public enum MLXProbeSupport {
    /// Seconds to the first generated text of `session`'s last turn, when it is an MLX session.
    public static func firstChunkSeconds(_ session: any LLMSession) async -> Double? {
        guard let session = session as? MLXSession else { return nil }
        return await session.lastFirstChunkSeconds
    }

    /// A token counter from the tokenizer files in `folder` (`tokenizer.json`; MLX and ANEMLL folders both
    /// have one), or nil when it does not load.
    public static func tokenCounter(folder: URL) async -> (@Sendable (String) -> Int)? {
        guard let tokenizer = try? await AutoTokenizer.from(modelFolder: folder) else { return nil }
        return { tokenizer.encode(text: $0, addSpecialTokens: false).count }
    }
}
