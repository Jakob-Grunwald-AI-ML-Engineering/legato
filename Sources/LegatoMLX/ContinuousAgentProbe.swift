import Foundation
import LegatoCore
import LegatoPostProcessing
import Tokenizers

// Spike #95: the continuous cleanup-agent workload, shared by the phone's session probe (internal builds) and
// the Mac runner (`spikes/continuous-agent`). A stream of 5–15-word chunks at speech pace goes into one warm
// session; after each chunk the model answers "no edit" (`[]`) or one edit (`{"sentence":n,"text":"…"}`).
// Backend-agnostic: the host builds the backend and samples memory, battery and thermal state itself.

/// What a corpus sentence should end up as after the agent's edits.
public enum ProbeExpectation: Sendable, Hashable {
    /// Unchanged: any edit is a false positive.
    case noEdit
    /// Exactly this text (whitespace-normalized).
    case becomes(String)
    /// None of these substrings may remain.
    case removes([String])
    /// No check.
    case unchecked
}

public struct ProbeSentence: Sendable, Hashable {
    /// The fixture (`P01`…`P12`), `T1`… for the WhatsApp transcript, `C1`… for clean context.
    public var id: String
    public var text: String
    public var expectation: ProbeExpectation
    public init(id: String, text: String, expectation: ProbeExpectation) {
        self.id = id; self.text = text; self.expectation = expectation
    }
}

public enum ProbeCorpus {
    /// `spikes/keyboard-corrections/Fixtures/patches.json` (old → new, as dictated sentences), Jakob's raw
    /// WhatsApp transcript, and clean sentences that need no edit (false-positive check).
    public static let sentences: [ProbeSentence] = [
        .init(id: "P01", text: "Send teh report while the meeting continues with no change to the remaining facts.",
              expectation: .becomes("Send the report while the meeting continues with no change to the remaining facts.")),
        .init(id: "T1", text: "Hello, I'm testing this out now, is with with obvious spelling mistakes, such as tea.",
              expectation: .removes(["with with"])),
        .init(id: "P02", text: "Send report while the meeting continues with no change to the remaining facts.",
              expectation: .becomes("Send the report while the meeting continues with no change to the remaining facts.")),
        .init(id: "T2", text: "Um, something.", expectation: .unchecked),
        .init(id: "T3", text: "Hmm.", expectation: .unchecked),
        .init(id: "C1", text: "The ferry to the island leaves at noon from the north pier.", expectation: .noEdit),
        .init(id: "P03", text: "Send the the report while the meeting continues with no change to the remaining facts.",
              expectation: .becomes("Send the report while the meeting continues with no change to the remaining facts.")),
        .init(id: "T4", text: "#um, I don't think it was doing like a proper replace finally replaced.",
              expectation: .removes(["#"])),
        .init(id: "T5", text: "Edit.", expectation: .unchecked),
        .init(id: "P04", text: "go go go home today.", expectation: .unchecked),
        .init(id: "T6", text: "#ah.", expectation: .removes(["#"])),
        .init(id: "C2", text: "We checked the anchor chain twice before the wind picked up in the evening.", expectation: .noEdit),
        .init(id: "P05", text: "Café and café remain.", expectation: .noEdit),
        .init(id: "T7", text: "I don't know.", expectation: .noEdit),
        .init(id: "P06", text: "Keep 👩🏽‍💻 teh 🇩🇪 flag and 👨‍👩‍👧‍👦.", expectation: .becomes("Keep 👩🏽‍💻 the 🇩🇪 flag and 👨‍👩‍👧‍👦.")),
        .init(id: "T8", text: "I don't think it's working.", expectation: .noEdit),
        .init(id: "P07", text: "send teh report.", expectation: .removes(["teh"])),
        .init(id: "C3", text: "Please book a table for four people on Friday at seven.", expectation: .noEdit),
        .init(id: "T9", text: "#HM, maybe some things are working.", expectation: .removes(["#"])),
        .init(id: "P08", text: "hello wor.", expectation: .unchecked),
        .init(id: "P09", text: "send teh report.", expectation: .removes(["teh"])),
        .init(id: "T10", text: "#um, I like to go to Te Beach.", expectation: .removes(["#", "Te Beach"])),
        .init(id: "P10", text: "send teh report.", expectation: .removes(["teh"])),
        .init(id: "C4", text: "The new sails arrive next week and the rigger will fit them on Tuesday.", expectation: .noEdit),
        .init(id: "P11", text: "hello world.", expectation: .becomes("Hello world.")),
        .init(id: "P12", text: "send teh report suffix.", expectation: .removes(["teh"])),
        .init(id: "C5", text: "After lunch we sailed back along the coast and reached the harbour before dark.", expectation: .noEdit),
    ]

    public static var wordCount: Int { sentences.reduce(0) { $0 + ProbeChunker.words($1.text).count } }
}

/// One piece of the stream: the words that arrive together.
public struct ProbeChunk: Sendable, Hashable {
    public var index: Int
    /// Each word with the stream sentence (1-based) it belongs to.
    public var words: [ProbeWord]
    /// Seconds from the stream's start until this chunk has been spoken (its last word).
    public var dueSeconds: Double
    /// How long this chunk takes to say: the time budget a turn has to keep up.
    public var speechSeconds: Double
    public var text: String { words.map(\.text).joined(separator: " ") }
}

public struct ProbeWord: Sendable, Hashable {
    public var text: String
    public var sentence: Int
}

/// The stream: the corpus repeated (rounds) until it lasts `targetSeconds` at `wordsPerSecond`, cut into
/// chunks of `minWords`…`maxWords` (seeded, so every run and backend sees the same chunks; the last chunk
/// may be shorter).
public enum ProbeChunker {
    public static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// The stream sentences (rounds of the corpus) for `targetSeconds` of speech.
    public static func sentences(corpus: [ProbeSentence], wordsPerSecond: Double, targetSeconds: Double) -> [ProbeSentence] {
        let perRound = corpus.reduce(0) { $0 + words($1.text).count }
        guard perRound > 0, wordsPerSecond > 0 else { return [] }
        let rounds = max(1, Int((targetSeconds * wordsPerSecond / Double(perRound)).rounded(.up)))
        return (1...rounds).flatMap { round in corpus.map { ProbeSentence(id: "\($0.id).r\(round)", text: $0.text, expectation: $0.expectation) } }
    }

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
            let size = low + Int(random.next() % UInt64(high - low + 1))
            let end = min(stream.count, position + size)
            let speech = Double(end - position) / wordsPerSecond
            chunks.append(ProbeChunk(index: chunks.count, words: Array(stream[position..<end]),
                                     dueSeconds: Double(end) / wordsPerSecond, speechSeconds: speech))
            position = end
        }
        return chunks
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

/// The shadow document: each stream sentence's words so far, with the agent's edits applied.
public struct ProbeDocument: Sendable {
    public struct Entry: Sendable, Hashable {
        public var source: ProbeSentence
        public var received: [String] = []
        public var total: Int
        /// The text after the agent's last edit, or nil while unedited.
        public var edited: String?
        public var edits = 0
        public var finished: Bool { received.count >= total }
        public var text: String { edited ?? received.joined(separator: " ") }
    }

    public private(set) var entries: [Entry]

    public init(sentences: [ProbeSentence]) {
        entries = sentences.map { Entry(source: $0, total: ProbeChunker.words($0.text).count) }
    }

    /// Adds the chunk's words; returns the sentence numbers it touched, in order.
    public mutating func receive(_ chunk: ProbeChunk) -> [Int] {
        var touched: [Int] = []
        for word in chunk.words {
            entries[word.sentence - 1].received.append(word.text)
            if touched.last != word.sentence { touched.append(word.sentence) }
        }
        return touched
    }

    public func entry(_ number: Int) -> Entry? { entries.indices.contains(number - 1) ? entries[number - 1] : nil }

    /// Applies an edit to a sentence that has arrived (at least partly). False when the number is unknown or
    /// the sentence has not started.
    @discardableResult
    public mutating func apply(_ edit: SentenceEdit) -> Bool {
        guard entries.indices.contains(edit.sentence - 1), !entries[edit.sentence - 1].received.isEmpty else { return false }
        entries[edit.sentence - 1].edited = edit.text
        entries[edit.sentence - 1].edits += 1
        return true
    }

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

/// The session head for the continuous agent: the live agent's instructions, narrowed to one edit per turn.
public enum ProbeInstructions {
    public static func head(locale: Locale = Locale(identifier: "en_US")) -> String {
        CleanupPrompt.Agent.instructions(locale: locale, style: .verbatim) + "\n" + #"""
        The text arrives in pieces while the user speaks. Each request lists the sentences the newest piece touched; earlier sentences are in the conversation above. Answer with exactly one JSON value and nothing else: [] when no sentence under "Review" needs a change, or {"sentence": n, "text": "the full corrected sentence"} for the single most needed change.
        """#
    }
}

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

/// Order statistics and rates over the per-chunk records.
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

    /// Percent of `flags` that are true (0 when empty).
    public static func percent(_ flags: [Bool]) -> Double {
        flags.isEmpty ? 0 : Double(flags.filter { $0 }.count) * 100 / Double(flags.count)
    }

    static func normalized(_ text: String) -> String {
        ProbeChunker.words(text).joined(separator: " ")
    }

    /// Whether `entry` meets its expectation: nil when unchecked or never finished.
    public static func check(_ entry: ProbeDocument.Entry) -> Bool? {
        guard entry.finished else { return nil }
        switch entry.source.expectation {
        case .unchecked: return nil
        case .noEdit: return entry.edits == 0 || normalized(entry.text) == normalized(entry.source.text)
        case .becomes(let target): return normalized(entry.text) == normalized(target)
        case .removes(let parts): return !parts.contains { entry.text.contains($0) }
        }
    }
}

/// One chunk's turn, as logged.
public struct ProbeTurnRecord: Sendable {
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
    public var ttftSource: String
    public var decodeTokens: Int?
    public var decodeMs: Int?
    public var totalMs: Int
    public var keptUp: Bool
    public var reply: String
    public var parseOK: Bool
    public var parseNote: String?
    public var edits: Int
    public var editsApplied: Int
    public var error: String?
    public var trimmed: Bool
    public var contextTokens: Int?

    public var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "chunk": chunk, "words": words, "speechMs": speechMs, "lagMs": lagMs, "ttftSource": ttftSource,
            "totalMs": totalMs, "keptUp": keptUp, "reply": String(reply.prefix(400)), "parseOk": parseOK,
            "edits": edits, "editsApplied": editsApplied, "trimmed": trimmed,
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

public struct ProbeSummary: Sendable {
    public var chunks: Int
    public var turnsFailed: Int
    public var medianMs: Double?
    public var p95Ms: Double?
    public var medianPrefillMs: Double?
    public var medianTtftMs: Double?
    public var medianDecodeTokensPerSecond: Double?
    public var keepUpPercent: Double
    public var maxLagMs: Int
    public var parseOKPercent: Double
    public var editsProduced: Int
    public var editsApplied: Int
    public var expectationsChecked: Int
    public var expectationsMet: Int
    /// Edits on sentences expected to stay unchanged.
    public var falsePositives: Int
    public var trims: Int
    public var failedChecks: [String]

    public init(records: [ProbeTurnRecord], document: ProbeDocument) {
        chunks = records.count
        turnsFailed = records.filter { $0.error != nil }.count
        let ok = records.filter { $0.error == nil }
        medianMs = ProbeStats.median(ok.map { Double($0.totalMs) })
        p95Ms = ProbeStats.percentile(ok.map { Double($0.totalMs) }, 95)
        medianPrefillMs = ProbeStats.median(ok.compactMap { $0.prefillMs.map(Double.init) })
        medianTtftMs = ProbeStats.median(ok.compactMap { $0.ttftMs.map(Double.init) })
        medianDecodeTokensPerSecond = ProbeStats.median(ok.compactMap { record in
            guard let tokens = record.decodeTokens, let ms = record.decodeMs, ms > 0, tokens > 0 else { return nil }
            return Double(tokens) * 1_000 / Double(ms)
        })
        keepUpPercent = ProbeStats.percent(records.map(\.keptUp))
        maxLagMs = records.map(\.lagMs).max() ?? 0
        parseOKPercent = ProbeStats.percent(records.map(\.parseOK))
        editsProduced = records.reduce(0) { $0 + $1.edits }
        editsApplied = records.reduce(0) { $0 + $1.editsApplied }
        trims = records.filter(\.trimmed).count
        var checked = 0, met = 0, falsePositives = 0
        var failed: [String] = []
        for entry in document.entries {
            if entry.source.expectation == .noEdit, entry.edits > 0, ProbeStats.check(entry) == false { falsePositives += 1 }
            guard let result = ProbeStats.check(entry) else { continue }
            checked += 1
            if result { met += 1 } else { failed.append(entry.source.id) }
        }
        expectationsChecked = checked; expectationsMet = met; self.falsePositives = falsePositives; failedChecks = failed
    }

    public var fields: [String: any Sendable] {
        var fields: [String: any Sendable] = [
            "chunks": chunks, "turnsFailed": turnsFailed, "keepUpPct": (keepUpPercent * 10).rounded() / 10,
            "maxLagMs": maxLagMs, "parseOkPct": (parseOKPercent * 10).rounded() / 10, "editsProduced": editsProduced,
            "editsApplied": editsApplied, "expectationsChecked": expectationsChecked, "expectationsMet": expectationsMet,
            "falsePositives": falsePositives, "trims": trims, "failedChecks": failedChecks.joined(separator: ","),
        ]
        if let medianMs { fields["medianMs"] = Int(medianMs) }
        if let p95Ms { fields["p95Ms"] = Int(p95Ms) }
        if let medianPrefillMs { fields["medianPrefillMs"] = Int(medianPrefillMs) }
        if let medianTtftMs { fields["medianTtftMs"] = Int(medianTtftMs) }
        if let medianDecodeTokensPerSecond { fields["medianDecodeTokPerS"] = (medianDecodeTokensPerSecond * 10).rounded() / 10 }
        return fields
    }
}

public struct ProbeConfig: Sendable {
    public var wordsPerSecond: Double
    public var targetSeconds: Double
    public var seed: UInt64
    /// The context the run keeps (tokens): trimmed to a third once past three quarters. The same for every
    /// backend (Core ML 1.7B's session budget is about 1,000), capped by the session's own budget.
    public var window: Int
    public init(wordsPerSecond: Double = 2.5, targetSeconds: Double = 150, seed: UInt64 = 95, window: Int = 1_000) {
        self.wordsPerSecond = wordsPerSecond; self.targetSeconds = targetSeconds; self.seed = seed; self.window = window
    }

    /// From `LEGATO_PROBE_WPS`, `LEGATO_PROBE_SECONDS`, `LEGATO_PROBE_SEED`, `LEGATO_PROBE_WINDOW`.
    public init(environment: [String: String]) {
        let defaults = ProbeConfig()
        self.init(wordsPerSecond: environment["LEGATO_PROBE_WPS"].flatMap(Double.init) ?? defaults.wordsPerSecond,
                  targetSeconds: environment["LEGATO_PROBE_SECONDS"].flatMap(Double.init) ?? defaults.targetSeconds,
                  seed: environment["LEGATO_PROBE_SEED"].flatMap(UInt64.init) ?? defaults.seed,
                  window: environment["LEGATO_PROBE_WINDOW"].flatMap(Int.init) ?? defaults.window)
    }
}

/// Replays the stream into one warm session at speech pace.
public enum ContinuousAgentProbe {
    public struct Hooks: Sendable {
        /// Tokens in a reply (the model's tokenizer), nil when unknown.
        public var countTokens: @Sendable (String) async -> Int?
        public var onTurn: @Sendable (ProbeTurnRecord) async -> Void
        /// Lines that are not turns: `warm`, `trim`, `stop`.
        public var onEvent: @Sendable (String, [String: any Sendable]) async -> Void
        public init(countTokens: @escaping @Sendable (String) async -> Int?,
                    onTurn: @escaping @Sendable (ProbeTurnRecord) async -> Void,
                    onEvent: @escaping @Sendable (String, [String: any Sendable]) async -> Void) {
            self.countTokens = countTokens; self.onTurn = onTurn; self.onEvent = onEvent
        }
    }

    public struct Result: Sendable {
        public var records: [ProbeTurnRecord]
        public var document: ProbeDocument
        public var summary: ProbeSummary { ProbeSummary(records: records, document: document) }
    }

    /// Opens the session (instructions, warm), then replays. Consecutive failures (3) or a closed session stop
    /// the run early; what was measured is returned.
    public static func run(backend: any LLMBackend, config: ProbeConfig, hooks: Hooks,
                           corpus: [ProbeSentence] = ProbeCorpus.sentences) async throws -> Result {
        let sentences = ProbeChunker.sentences(corpus: corpus, wordsPerSecond: config.wordsPerSecond, targetSeconds: config.targetSeconds)
        let chunks = ProbeChunker.chunks(sentences: sentences, wordsPerSecond: config.wordsPerSecond, seed: config.seed)
        var document = ProbeDocument(sentences: sentences)
        let session = try await backend.makeSession()
        let head = ProbeInstructions.head()
        try await session.append(.instructions(head))
        let clock = ContinuousClock()
        let warmStart = clock.now
        try await session.warm()
        let warmMetrics = await (session as? any LLMSessionMetrics)?.lastWarmMetrics()
        var warmFields: [String: any Sendable] = ["wallMs": ms(clock.now - warmStart), "tokenBudget": session.tokenBudget,
                                                   "chunksPlanned": chunks.count, "sentences": sentences.count,
                                                   "speechSeconds": Int(chunks.last?.dueSeconds ?? 0)]
        if let tokens = warmMetrics?.prefilledTokens { warmFields["prefillTokens"] = tokens }
        await hooks.onEvent("warm", warmFields)

        let window = min(config.window, session.tokenBudget)
        var context: Int?
        var records: [ProbeTurnRecord] = []
        var failuresInARow = 0
        let start = clock.now
        for chunk in chunks {
            let due = start + .milliseconds(Int(chunk.dueSeconds * 1_000))
            if clock.now < due { try? await Task.sleep(until: due, clock: clock) }
            let lag = clock.now - due
            let touched = document.receive(chunk)
            var trimmed = false
            if let tokens = context, tokens > window * 3 / 4 {
                do {
                    try await session.trim(keepingSuffix: window / 3)
                    trimmed = true
                    await hooks.onEvent("trim", ["chunk": chunk.index, "contextTokens": tokens, "keep": window / 3])
                } catch {
                    await hooks.onEvent("trim", ["chunk": chunk.index, "error": "\(error)"])
                }
            }
            let request = document.request(touched: touched)
            let turnStart = clock.now
            var record = ProbeTurnRecord(
                chunk: chunk.index, words: chunk.words.count, speechMs: Int(chunk.speechSeconds * 1_000), lagMs: max(0, ms(lag)),
                ttftSource: "prefill", totalMs: 0, keptUp: false, reply: "", parseOK: false, edits: 0, editsApplied: 0,
                trimmed: trimmed)
            do {
                let reply = try await session.respond(to: request)
                let total = clock.now - turnStart
                record.totalMs = ms(total)
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
                record.editsApplied = parsed.edits.filter { document.apply($0) }.count
                if let prompt = record.promptTokens { context = prompt + (record.decodeTokens ?? 0) }
                failuresInARow = 0
            } catch {
                record.totalMs = ms(clock.now - turnStart)
                record.error = String(describing: error).prefix(300).description
                failuresInARow += 1
            }
            record.contextTokens = context
            records.append(record)
            await hooks.onTurn(record)
            if let error = record.error, failuresInARow >= 3 || error.contains("closed") {
                await hooks.onEvent("stop", ["chunk": chunk.index, "reason": failuresInARow >= 3 ? "3 failures in a row" : "session closed"])
                break
            }
        }
        await session.close()
        return Result(records: records, document: document)
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
