import Foundation
import LegatoCore
import LegatoPostProcessing

// Spike #95, rewrite mode: an endpointer cuts the ASR stream into sentences, only a finished sentence goes to the
// model, the model answers that sentence rewritten in plain text, and code turns the difference between the
// original ASR words and the reply into targeted word patches (rejected when the reply drifted). Two prompt
// layouts: `onepass` (one fresh request per sentence: head, rolling text so far, the sentence) and `turns` (one
// warm session: head, then the sentence as a user turn and the rewrite as the assistant turn). The context stays
// at a fixed share of the model's window on every request; the oldest history goes first.

/// What the agent is asked for.
public enum ProbeMode: String, Sendable, Hashable, CaseIterable {
    /// Per chunk: `[]` or one structured edit `{"sentence":n,"text":…}` (the first probe).
    case edits
    /// Per endpointed sentence: the sentence rewritten in plain text, merged by a word diff.
    case rewrite
}

/// How a rewrite request is laid out.
public enum ProbeLayout: String, Sendable, Hashable, CaseIterable {
    /// One fresh request per sentence: head + rolling text so far (edits applied) + the sentence.
    case onepass
    /// One warm session: head, then `User: sentence` → `Assistant: rewrite` per sentence.
    case turns
}

// MARK: - Endpointing

/// Decides when the stream has completed a sentence: a word that ends with terminal punctuation, a pause of at
/// least ``Config/pauseSeconds`` between two words, or ``Config/maxWords`` words without an end (run-ons still
/// get processed). The rest of the stream is ready at its end.
public struct ProbeEndpointer: Sendable {
    public struct Config: Sendable, Hashable {
        public var pauseSeconds: Double
        public var maxWords: Int
        public init(pauseSeconds: Double = 0.7, maxWords: Int = 30) { self.pauseSeconds = pauseSeconds; self.maxWords = maxWords }
    }

    public enum Reason: String, Sendable, Hashable { case punctuation, pause, length, end }

    /// One sentence ready for the model.
    public struct Ready: Sendable, Hashable {
        /// Stream word positions (0-based, run-local).
        public var words: Range<Int>
        public var reason: Reason
        /// Stream seconds when its last word was spoken.
        public var lastWordSeconds: Double
        /// Stream seconds when the endpointer could tell: the chunk's delivery, or the end of the pause.
        public var detectedSeconds: Double
        public var delaySeconds: Double { max(0, detectedSeconds - lastWordSeconds) }
    }

    public let config: Config
    private var start = 0
    private var count = 0
    private var lastWordSeconds: Double?

    public init(config: Config = Config()) { self.config = config }

    /// Words spoken at `times` (stream seconds, ascending) and delivered together at `deliveredSeconds`.
    public mutating func receive(_ words: [String], times: [Double], deliveredSeconds: Double) -> [Ready] {
        var ready: [Ready] = []
        for (word, time) in zip(words, times) {
            if let last = lastWordSeconds, count > start, time - last >= config.pauseSeconds {
                ready.append(emit(.pause, detected: last + config.pauseSeconds))
            }
            count += 1
            lastWordSeconds = time
            if Self.endsSentence(word) {
                ready.append(emit(.punctuation, detected: deliveredSeconds))
            } else if count - start >= config.maxWords {
                ready.append(emit(.length, detected: deliveredSeconds))
            }
        }
        return ready
    }

    /// No new words until `now`: what is pending is ready once the pause is long enough.
    public mutating func silence(until now: Double) -> Ready? {
        guard let last = lastWordSeconds, count > start, now - last >= config.pauseSeconds else { return nil }
        return emit(.pause, detected: last + config.pauseSeconds)
    }

    /// The end of the stream: whatever is pending.
    public mutating func finish(at seconds: Double) -> Ready? {
        guard count > start else { return nil }
        return emit(.end, detected: max(seconds, lastWordSeconds ?? seconds))
    }

    private mutating func emit(_ reason: Reason, detected: Double) -> Ready {
        defer { start = count }
        return Ready(words: start..<count, reason: reason, lastWordSeconds: lastWordSeconds ?? detected, detectedSeconds: detected)
    }

    private static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "e.g.", "i.e.", "approx.", "no."]

    /// Ends with `.`, `!`, `?` or `…` (closing quotes and brackets after it allowed), and is not a title or
    /// "e.g.".
    public static func endsSentence(_ word: String) -> Bool {
        var trimmed = Substring(word)
        while let last = trimmed.last, "\"')]}”’»".contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last, ".!?…".contains(last) else { return false }
        return last != "." || !abbreviations.contains(trimmed.lowercased())
    }
}

// MARK: - Word diff

/// The minimal word-level changes from one text to another (longest common subsequence of words, compared
/// exactly, punctuation included): each hunk replaces a run of old words, possibly empty, with new words.
public enum ProbeWordDiff {
    public struct Hunk: Sendable, Hashable {
        /// Old word positions replaced (empty: an insertion before `removed.lowerBound`).
        public var removed: Range<Int>
        public var inserted: [String]
        public init(removed: Range<Int>, inserted: [String]) { self.removed = removed; self.inserted = inserted }
    }

    public static func hunks(_ old: [String], _ new: [String]) -> [Hunk] {
        let n = old.count, m = new.count
        // lcs[i][j]: the longest common subsequence of old[i...] and new[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var open: (start: Int, inserted: [String])?
        func close() { if let o = open { hunks.append(Hunk(removed: o.start..<i, inserted: o.inserted)); open = nil } }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                close(); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                if open == nil { open = (i, []) }
                open!.inserted.append(new[j]); j += 1
            } else {
                if open == nil { open = (i, []) }
                i += 1
            }
        }
        close()
        return hunks
    }
}

// MARK: - Document

/// The stream's words as the ASR wrote them, each with its current text after the agent's patches ("" when
/// removed; an insertion joins the word it precedes, or the segment's last word).
public struct ProbeRewriteDocument: Sendable {
    public private(set) var words: [ProbeWord] = []
    public private(set) var slots: [String] = []
    public let sentences: [ProbeSentence]

    public init(sentences: [ProbeSentence]) { self.sentences = sentences }

    public mutating func receive(_ chunk: ProbeChunk) {
        words += chunk.words
        slots += chunk.words.map(\.text)
    }

    public func original(_ range: Range<Int>) -> String { words[range].map(\.text).joined(separator: " ") }
    public func current(_ range: Range<Int>) -> String { Self.join(slots[range]) }

    /// The current text of corpus sentence `index` (0-based), as far as it was received.
    public func sentenceText(_ index: Int) -> String {
        Self.join(zip(words, slots).filter { $0.0.sentence == index + 1 }.map(\.1))
    }

    /// Applies `hunks` (positions relative to `range`'s original words). Returns the touched corpus sentences
    /// (0-based) with their text before, in order.
    public mutating func apply(_ hunks: [ProbeWordDiff.Hunk], in range: Range<Int>) -> [(sentence: Int, before: String)] {
        var touched: [Int] = []
        var before: [Int: String] = [:]
        func touch(_ position: Int) {
            let sentence = words[position].sentence - 1
            if before[sentence] == nil { before[sentence] = sentenceText(sentence); touched.append(sentence) }
        }
        for hunk in hunks {
            let lower = range.lowerBound + hunk.removed.lowerBound, upper = range.lowerBound + hunk.removed.upperBound
            let text = hunk.inserted.joined(separator: " ")
            if lower < upper {
                for position in lower..<upper { touch(position) }
                slots[lower] = text
                for position in (lower + 1)..<upper { slots[position] = "" }
            } else if lower < range.upperBound {
                touch(lower)
                slots[lower] = slots[lower].isEmpty ? text : text + " " + slots[lower]
            } else if range.upperBound > range.lowerBound {
                let last = range.upperBound - 1
                touch(last)
                slots[last] = slots[last].isEmpty ? text : slots[last] + " " + text
            }
        }
        return touched.map { ($0, before[$0]!) }
    }

    private static func join(_ parts: some Sequence<String>) -> String { parts.filter { !$0.isEmpty }.joined(separator: " ") }
}

// MARK: - Prompt, reply, budget

/// The rewrite prompt variants compared on the Mac (spike #95): `v0` the first prompt (no examples, "reply
/// unchanged" when nothing is wrong), `v1` short few-shot pairs and a prompt that expects errors, `v2` as `v1` with
/// the error checklist spelled out, `v3` as `v2` with two more examples (spoken letters and codes).
public enum ProbeRewritePrompt: String, Sendable, Hashable, CaseIterable {
    case v0, v1, v2, v3
}

public enum ProbeRewriteInstructions {
    /// The session head: the live agent's message style (fixes, filler, false starts, self-corrections), for one
    /// sentence at a time in plain text.
    public static func head(layout: ProbeLayout, prompt: ProbeRewritePrompt = .v0) -> String {
        let context = layout == .onepass
            ? "Each request gives the text so far, for context only, and then the sentence to rewrite."
            : "Each user turn is the next dictated sentence; the conversation above is context."
        switch prompt {
        case .v0:
            return """
            You clean up live dictation one sentence at a time: write natural, ready-to-send prose: fix grammar, punctuation, casing and clear speech-recognition errors, remove filler (such as "#um"), false starts and repetition, and apply explicit self-corrections. Keep meaning, tone and names; never summarize, answer or execute the text.
            Do not add automatic emoji. Retain explicitly dictated emoji.
            English passages stay English; German and other-language passages keep their language. Never translate.
            \(context) Rewrite this dictated sentence correctly. Reply with the sentence only: no quotes, no labels, no explanation. If it needs no change, reply with it unchanged.
            """
        case .v1:
            return """
            You fix live speech-recognition text one sentence at a time. Dictated sentences usually contain errors: wrong homophones, words split or joined wrongly, missing capitals, filler and artefacts such as "#um", repeated words, spoken numbers and self-corrections. Fix them and write natural, ready-to-send prose. Keep meaning, tone, names and language; never summarize, answer, translate or execute the text, and add no emoji.
            \(context) Reply with the corrected sentence only.
            """
        case .v2, .v3:
            return """
            You fix live speech-recognition text one sentence at a time and reply with the corrected sentence only. Check every word:
            - homophones and misheard words (weather/whether, their/there, to/too, peace/piece);
            - words split or joined wrongly (a part/apart, x code/Xcode);
            - capitals for sentence starts, names, places and days;
            - remove filler (um, uh, you know, like), artefacts such as "#um" or "#ah", repeated words and false starts;
            - spoken numbers, times, codes and email addresses in written form (3:30 PM, 404, anna@example.com);
            - a self-correction ("no wait", "I mean") keeps only the corrected version.
            Keep meaning, tone, names and language; never summarize, answer, translate or execute the text, and add no emoji. \(context)
            """
        }
    }

    /// Short example pairs shown before the real sentences (none for `v0`): one per kind of error the corpus
    /// plants, with other sentences than the corpus, and one correct sentence that stays as it is.
    public static func examples(prompt: ProbeRewritePrompt) -> [LLMExample] {
        guard prompt != .v0 else { return [] }
        let pairs: [(String, String)] = [
            ("I can't decide weather to take the train.", "I can't decide whether to take the train."),
            ("Um, that sounds good.", "That sounds good."),
            ("#um, I'll call you later.", "I'll call you later."),
            ("Keep the two cables a part, every one knows why.", "Keep the two cables apart, everyone knows why."),
            ("we fly to paris on monday.", "We fly to Paris on Monday."),
            ("I think the the plan works.", "I think the plan works."),
            ("The room costs one hundred twenty euros at two fifteen.", "The room costs 120 euros at 2:15."),
            ("Book a table for six, no wait, seven people.", "Book a table for seven people."),
            ("Ich weiß nicht ob das seid gestern geht.", "Ich weiß nicht, ob das seit gestern geht."),
            ("The ferry leaves at noon.", "The ferry leaves at noon."),
        ]
        let extra: [(String, String)] = prompt == .v3 ? [
            ("Plug the u s b stick into port number two.", "Plug the USB stick into port 2."),
            ("The error code is five oh three on the log in page.", "The error code is 503 on the login page."),
        ] : []
        return (pairs + extra).map { LLMExample(user: $0.0, assistant: $0.1) }
    }

    /// The user message: the sentence, after the text so far in `onepass`.
    public static func request(sentence: String, history: [String], layout: ProbeLayout) -> String {
        guard layout == .onepass, !history.isEmpty else { return sentence }
        return "Text so far:\n\(history.joined(separator: " "))\n\nSentence:\n\(sentence)"
    }
}

public enum ProbeRewriteReply {
    /// The rewritten sentence: think blocks, labels, wrapping quotes and line breaks removed; nil when empty.
    public static func clean(_ raw: String) -> String? {
        var text = raw
        while let open = text.range(of: "<think>") {
            let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }
        text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        for label in ["Assistant:", "Sentence:", "Rewritten:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("`", "`")] where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }
}

/// The context share kept on every request.
public enum ProbeContextBudget {
    /// Tokens a reply to `sentenceTokens` may take: twice the sentence plus a little.
    public static func replyReserve(sentenceTokens: Int) -> Int { sentenceTokens * 2 + 16 }

    /// How many of the oldest `history` entries (token counts, oldest first) to drop so that `fixed` (head,
    /// sentence, labels, reply reserve) plus the rest fit `budget`. All of them when even none fits.
    public static func dropCount(fixed: Int, history: [Int], budget: Int) -> Int {
        var total = fixed + history.reduce(0, +)
        var dropped = 0
        while total > budget, dropped < history.count {
            total -= history[dropped]
            dropped += 1
        }
        return dropped
    }
}

/// What one reply did to the document.
public struct ProbeRewriteOutcome: Sendable {
    public var accepted: Bool
    public var drift: Double
    public var hunks: [ProbeWordDiff.Hunk]
    /// Corpus sentences (0-based) the patches changed, with their text before and after.
    public var changed: [(sentence: Int, before: String, after: String)]
}

/// Whether a rewritten sentence still says what was dictated. Either guard may accept it: the message guard
/// (drops filler, false starts and self-corrections; its content words must come from the input) or a word drift
/// of at most 40 % (brings in the written forms the message guard counts as new words: "x code" → "Xcode",
/// "four oh four" → "404", "their" → "there"). A translation or an answer fails both.
public enum ProbeRewriteGuard {
    public static let drift = CleanupGuard(maxDrift: 0.4)

    public static func accepts(_ candidate: String, reference: String) -> Bool {
        CleanupGuard.message.accepts(candidate, reference: reference) || drift.accepts(candidate, reference: reference)
    }
}

public enum ProbeRewriteMerge {
    /// Diffs the original ASR words of `range` against `reply` and applies the patches, unless the drift guard
    /// rejects the reply (then the document is unchanged).
    public static func merge(_ reply: String, into document: inout ProbeRewriteDocument, range: Range<Int>) -> ProbeRewriteOutcome {
        let original = document.original(range)
        let score = ProbeRewriteGuard.drift.drift(candidate: reply, reference: original)
        guard ProbeRewriteGuard.accepts(reply, reference: original) else {
            return ProbeRewriteOutcome(accepted: false, drift: score, hunks: [], changed: [])
        }
        let hunks = ProbeWordDiff.hunks(ProbeChunker.words(original), ProbeChunker.words(reply))
        let touched = document.apply(hunks, in: range)
        return ProbeRewriteOutcome(accepted: true, drift: score, hunks: hunks,
                                   changed: touched.map { ($0.sentence, $0.before, document.sentenceText($0.sentence)) })
    }
}

// MARK: - Run

extension ContinuousAgentProbe {
    /// One pass of the stream in rewrite mode on `session` (its head is ``ProbeRewriteInstructions/head(layout:)``).
    static func replayRewrite(session: any LLMSession, corpus: [ProbeSentence], config: ProbeConfig, rep: Int, phase: String,
                              seed: UInt64, hooks: Hooks) async -> ProbeRunResult {
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
        var document = ProbeRewriteDocument(sentences: corpus)
        var endpointer = ProbeEndpointer(config: config.endpoint)
        var processed: [Range<Int>] = []
        var editOutcomes: [ProbeEditOutcome] = []
        var records: [ProbeTurnRecord] = []
        var failuresInARow = 0
        var stopped = false
        let window = config.contextWindow ?? session.tokenBudget
        let budget = min(session.tokenBudget, window * config.contextPercent / 100)
        let head = ProbeRewriteInstructions.head(layout: config.layout, prompt: config.prompt)
        func count(_ text: String) async -> Int { await hooks.countTokens(text) ?? (text.utf8.count + 2) / 3 }
        var headTokens = await count(head)
        for example in ProbeRewriteInstructions.examples(prompt: config.prompt) {
            headTokens += await count(example.user) + count(example.assistant) + 8  // plus the chat-template markers
        }
        let clock = ContinuousClock()
        let start = clock.now
        func seconds(_ instant: ContinuousClock.Instant) -> Double { Double(ms(instant - start)) / 1_000 }

        func request(_ ready: ProbeEndpointer.Ready, chunk: ProbeChunk) async {
            let sentence = document.original(ready.words)
            let due = start + .milliseconds(Int(ready.detectedSeconds * 1_000))
            var record = ProbeTurnRecord(rep: rep, phase: phase, chunk: chunk.index, words: ready.words.count,
                                         speechMs: Int(Double(ready.words.count) / config.wordsPerSecond * 1_000),
                                         lagMs: max(0, ms(clock.now - due)))
            record.endpoint = ready.reason.rawValue
            record.endpointDelayMs = Int((ready.delaySeconds * 1_000).rounded())
            record.ctxWindow = window; record.ctxBudget = budget
            let sentenceTokens = await count(sentence)
            let reserve = ProbeContextBudget.replyReserve(sentenceTokens: sentenceTokens)
            let message: String
            do {
                switch config.layout {
                case .onepass:
                    // Fresh per request: drop the previous turn (the head stays; Core ML keeps it prefilled).
                    try await session.trim(keepingSuffix: 0)
                    var history = processed.map { document.current($0) }
                    var counts: [Int] = []
                    for text in history { counts.append(await count(text)) }
                    let labels = await count(ProbeRewriteInstructions.request(sentence: "", history: [""], layout: .onepass))
                    let drop = ProbeContextBudget.dropCount(fixed: headTokens + sentenceTokens + labels + reserve, history: counts, budget: budget)
                    history.removeFirst(drop)
                    record.historyDropped = drop
                    message = ProbeRewriteInstructions.request(sentence: sentence, history: history, layout: .onepass)
                    record.ctxTokens = headTokens + labels + sentenceTokens + counts.dropFirst(drop).reduce(0, +)
                case .turns:
                    let usage = try await session.usage()
                    if usage.total + sentenceTokens + reserve > budget {
                        try await session.trim(keepingSuffix: max(0, budget - usage.head - sentenceTokens - reserve))
                        record.trimmed = true
                    }
                    message = sentence
                    record.ctxTokens = (try await session.usage()).total + sentenceTokens
                }
            } catch {
                record.error = String(String(describing: error).prefix(300))
                records.append(record); await hooks.onTurn(record)
                failuresInARow += 1
                return
            }
            let turnStart = clock.now
            do {
                let reply = try await session.respond(to: message)
                let end = clock.now
                record.totalMs = ms(end - turnStart)
                record.keptUp = record.totalMs < record.speechMs
                record.reply = reply
                await measure(&record, session: session, reply: reply, hooks: hooks)
                processed.append(ready.words)
                failuresInARow = 0
                guard let cleaned = ProbeRewriteReply.clean(reply) else {
                    record.parseOK = false; record.parseNote = "empty"
                    records.append(record); await hooks.onTurn(record)
                    return
                }
                record.parseOK = true
                let merged = ProbeRewriteMerge.merge(cleaned, into: &document, range: ready.words)
                record.drift = (merged.drift * 100).rounded() / 100
                record.rejected = !merged.accepted
                record.edits = merged.hunks.count
                if !merged.accepted {
                    await hooks.onEvent("reject", ["rep": rep, "phase": phase, "chunk": chunk.index, "drift": record.drift ?? 0,
                                                   "sentence": String(sentence.prefix(300)), "reply": String(cleaned.prefix(300))])
                }
                for change in merged.changed {
                    let source = corpus[change.sentence]
                    let effect = ProbeEditEffect.evaluate(before: change.before, after: change.after, mistakes: source.mistakes,
                                                          fixedBefore: outcomes[change.sentence].map { $0.fixedChunk != nil })
                    record.editsApplied += 1
                    if effect.wrong { record.wrongEdits += 1 }
                    for m in effect.fixed {
                        outcomes[change.sentence][m].fixedChunk = chunk.index
                        outcomes[change.sentence][m].fixedSeconds = seconds(end)
                        record.fixed.append("\(source.id):\(source.mistakes[m].wrong)")
                    }
                    for m in effect.regressed {
                        outcomes[change.sentence][m].regressed = true
                        outcomes[change.sentence][m].fixedChunk = nil; outcomes[change.sentence][m].fixedSeconds = nil
                    }
                    editOutcomes.append(ProbeEditOutcome(rep: rep, chunk: chunk.index, passage: source.passage, tags: source.tags,
                                                         applied: true, wrong: effect.wrong, noop: effect.noop))
                }
            } catch {
                record.totalMs = ms(clock.now - turnStart)
                record.error = String(String(describing: error).prefix(300))
                failuresInARow += 1
            }
            record.contextTokens = record.promptTokens.map { $0 + (record.decodeTokens ?? 0) }
            records.append(record)
            await hooks.onTurn(record)
            if let error = record.error, failuresInARow >= 3 || error.contains("closed") {
                await hooks.onEvent("stop", ["rep": rep, "phase": phase, "chunk": chunk.index,
                                             "reason": failuresInARow >= 3 ? "3 failures in a row" : "session closed"])
                stopped = true
            }
        }

        for chunk in chunks where !stopped {
            let due = start + .milliseconds(Int(chunk.dueSeconds * 1_000))
            if clock.now < due { try? await Task.sleep(until: due, clock: clock) }
            document.receive(chunk)
            let times = chunk.words.indices.map { Double(chunk.firstWord + $0 + 1) / config.wordsPerSecond }
            var ready = endpointer.receive(chunk.words.map(\.text), times: times, deliveredSeconds: chunk.dueSeconds)
            if chunk.index == chunks.count - 1, let rest = endpointer.finish(at: chunk.dueSeconds) { ready.append(rest) }
            for sentence in ready where !stopped { await request(sentence, chunk: chunk) }
        }
        let flat = outcomes.flatMap { $0 }
        for outcome in flat { await hooks.onEvent("mistake", outcome.fields) }
        return ProbeRunResult(rep: rep, phase: phase, records: records, mistakes: flat, edits: editOutcomes,
                              wallSeconds: seconds(clock.now))
    }
}
