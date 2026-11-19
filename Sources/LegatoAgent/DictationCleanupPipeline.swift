import Foundation

/// A dictated line ready to type: the cleaned text, or the raw line when cleanup failed, timed out or was rejected.
public struct DictationCleanedLine: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable, Codable { case cleaned, raw }
    public let sequence: Int
    public let lineID: String
    public let raw: String
    public let text: String
    public let status: Status
    /// Why the raw line was used (`timeout`, `failed`, `rejected`); nil when cleaned. No dictated text.
    public let reason: String?
    /// What failed, for diagnostics (an error case or type name, never text); nil when cleaned or timed out.
    public var detail: String? = nil
    /// How the request went (nil when none finished, or for a speculative result reused: those are the speculation's own).
    public var metrics: CleanupMetrics? = nil
    /// Milliseconds the line waited for a free slot before its request began (nil when not measured).
    public var queueWaitMs: Int? = nil
    /// Whether the result came from a speculative request (`speculate`): `landed` was already done when the line began
    /// cleaning, `inflight` it was still running and was awaited, nil: no speculation was used.
    public var speculation: String? = nil
    public static func == (a: Self, b: Self) -> Bool {
        a.sequence == b.sequence && a.lineID == b.lineID && a.raw == b.raw && a.text == b.text && a.status == b.status
            && a.reason == b.reason && a.detail == b.detail
    }
}

/// Sanity checks for conservative cleanup. Staged sends may compose or rewrite from spoken directions,
/// so only the empty-result check applies to them.
///
/// An empty result (nothing but whitespace) drops the line. It is accepted only for a line that can carry no
/// meaning: every word a filler (`fillers`), or at most `droppableWords` words; a longer line that comes back empty
/// is rejected (the model lost it). Callers that cannot drop a line treat an empty result as a failure.
public enum DictationCleanupGuard {
    /// A line of at most this many words may be dropped whole (an empty cleanup result).
    public static let droppableWords = 3
    /// Words that carry no meaning alone (English and German speech tics), lowercased.
    public static let fillers: Set<String> = [
        "um", "umm", "ummm", "uhm", "uh", "uhh", "er", "erm", "ah", "ahh", "eh", "oh", "hm", "hmm", "mm", "mhm", "mmh",
        "yeah", "yep", "ok", "okay", "so", "well", "like", "right", "you", "know", "i", "mean", "basically", "and",
        "äh", "ähm", "öh", "öhm", "ja", "ne", "na", "naja", "also", "halt", "sozusagen", "quasi", "genau",
    ]

    /// Whether dropping `raw` entirely (an empty cleanup result) is a sane cleanup of it.
    public static func acceptsDrop(raw: String) -> Bool {
        let source = tokens(raw)
        return prepositionalUm(raw) == 0 && (source.count <= droppableWords || source.allSatisfy(fillers.contains))
    }

    /// Words after which a German "um" is a preposition (a time, a number, an amount), not a filler.
    private static let umObjects: Set<String> = [
        "null", "eins", "ein", "eine", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf",
        "zwanzig", "dreißig", "vierzig", "fünfzig", "hundert", "tausend", "halb", "viertel", "punkt", "mitternacht", "mittag",
        "wie", "welche", "wieviel", "wie viel", "ca", "circa", "etwa", "die", "den", "das", "dich", "mich", "uns", "euch", "ihn", "sie", "es",
    ]
    /// How many times `um` stands as a German preposition in `text`: before a digit, a number word or a time word.
    static func prepositionalUm(_ text: String) -> Int {
        let words = tokens(text)
        return words.indices.dropLast().filter { i in
            words[i] == "um" && (words[i + 1].first?.isNumber == true || umObjects.contains(words[i + 1]))
        }.count
    }
    /// A cleanup may not drop every German "um" that is a preposition ("um sechs Uhr"): it is no filler. One may go
    /// in a self-correction ("um drei, nein, um vier").
    public static func keepsPrepositions(raw: String, cleaned: String) -> Bool {
        prepositionalUm(raw) == 0 || prepositionalUm(cleaned) > 0
    }

    public static func accepts(raw: String, cleaned: String, style: DictationCleanupStyle = .line) -> Bool {
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cleaned.contains(where: \.isNewline) { return acceptsDrop(raw: raw) }
        if style == .send { return true }
        let source = tokens(raw), result = tokens(cleaned)
        guard keepsPrepositions(raw: raw, cleaned: cleaned) else { return false }
        guard !cleaned.isEmpty, cleaned.count <= max(48, raw.count * 3 / 2 + 24) else { return false }
        if result.isEmpty { return true } // a bare line break or punctuation from a spoken command
        // A few words: too few to count overlap, so the result must sound like them (an ASR fix) or share a word.
        guard source.count > 3 else {
            return result.count <= source.count + 3 && (!Set(source).isDisjoint(with: result) || resembles(source.joined(), result.joined()))
        }
        guard result.count <= source.count + 4, result.count * 5 >= source.count else { return false }
        // A line that was mostly filler may shrink to a fifth of its words. Most of the result's words must be words the speaker said (ASR fixes and spoken commands may differ).
        let said = Set(source)
        let known = result.filter { said.contains($0) }.count
        return known * 2 >= result.count
    }
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    /// At most half of the longer text differs (Levenshtein distance).
    private static func resembles(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in a.indices {
            var diagonal = row[0]
            row[0] = i + 1
            for j in b.indices {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (a[i] == b[j] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count] * 2 <= max(a.count, b.count)
    }
}

/// Cleans dictated lines one call each, up to `maxConcurrency` in flight at once, and hands them on strictly in speaking order
/// (a later line that finishes first waits for the earlier ones).
/// A line whose call fails, is rejected by the guard or takes longer than `timeout` goes on raw: dictation never
/// waits on the model beyond that.
public actor DictationCleanupPipeline {
    private struct Pending { let sequence: Int; let lineID: String; let raw: String; let textBefore: String; let allowsEmpty: Bool; let enqueued: ContinuousClock.Instant }
    /// A speculative request (`speculate`): the text it cleans, what stood before it, and its running task.
    private struct Speculation {
        let id: UUID; let raw: String; let textBefore: String
        let task: Task<ValidatedSentence, any Error>
        var settled = false
    }
    private var speculation: Speculation?
    /// Lines cleaned at once. Units are independent requests; delivery order is kept by sequence below, so more slots only
    /// remove queueing (two slots made units wait behind each other).
    public static let maxConcurrency = 6
    private let cleaner: any SentenceCleaning
    private let vocabulary: [String]
    /// The prompt every unit of this pipeline is cleaned with (`DictationCleanupStyle`); the guard judges by it too.
    public nonisolated let style: DictationCleanupStyle
    private let timeout: Duration
    private let concurrency: Int
    private let deliver: @Sendable (DictationCleanedLine) async -> Void
    private var queue: [Pending] = []
    private var inFlight: Set<Int> = []
    private var finished: [Int: DictationCleanedLine] = [:]
    private var nextDelivery = 0
    private var delivering = false
    private var firstSequence: Int?
    /// The best known text of each line so far: the raw line while its call runs, then what was delivered.
    private var known: [Int: String] = [:]
    private var generation = UUID()
    private var tasks: [Int: Task<Void, Never>] = [:]

    public init(cleaner: any SentenceCleaning, vocabulary: [String] = [], style: DictationCleanupStyle = .line, timeout: Duration = .milliseconds(2500),
                concurrency: Int = 4, deliver: @escaping @Sendable (DictationCleanedLine) async -> Void) {
        self.cleaner = cleaner; self.style = style
        self.vocabulary = Array(vocabulary.prefix(200))
        self.timeout = timeout; self.concurrency = max(1, min(Self.maxConcurrency, concurrency)); self.deliver = deliver
    }

    public var inFlightCount: Int { inFlight.count }

    public func warm() async { await cleaner.warmDictation(style) }

    /// `textBefore`: the field's text before the cursor now (`documentContextBeforeInput`). `allowsEmpty`: the caller
    /// can drop the line, so an empty result the guard accepts is delivered as cleaned empty text; otherwise an empty
    /// result is a failure (`invalidText`) and the raw line goes on.
    public func submit(sequence: Int, lineID: String, raw: String, textBefore: String, allowsEmpty: Bool = false) async {
        // Lines that never came here (another send mode took them) leave a gap: with nothing waiting, start at this one.
        if firstSequence == nil || (queue.isEmpty && inFlight.isEmpty && finished.isEmpty && sequence != nextDelivery) {
            firstSequence = firstSequence ?? sequence; nextDelivery = sequence
        }
        known[sequence] = raw
        queue.append(Pending(sequence: sequence, lineID: lineID, raw: raw, textBefore: String(textBefore.suffix(600)), allowsEmpty: allowsEmpty, enqueued: .now))
        queue.sort { $0.sequence < $1.sequence }
        pump()
    }

    /// Starts cleaning `raw` before its unit is sent (the voice agents' speculative turn): nothing is delivered. When a line
    /// with exactly this text (and `textBefore`) is submitted later, it takes this result (waiting for it if still running);
    /// any other line, or `cancelSpeculation()`, drops it. One speculative request at a time: a newer one cancels the older.
    /// Returns false when this exact text is already being cleaned speculatively.
    @discardableResult
    public func speculate(lineID: String, sequence: Int, raw: String, textBefore: String) -> Bool {
        let before = String(textBefore.suffix(600))
        if let current = speculation, current.raw == raw, current.textBefore == before { return false }
        speculation?.task.cancel()
        let previous = known.filter { $0.key < sequence }.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.suffix(2).map { $0 }
        let input = SentenceCleanupInput(sentenceID: lineID, sequence: sequence, text: raw, vocabulary: vocabulary,
                                         dictation: .init(previousLines: previous, textBeforeCursor: before, style: style))
        let id = UUID()
        let task = Task<ValidatedSentence, any Error> { [weak self, cleaner] in
            do {
                let sentence = try await cleaner.clean(input)
                await self?.settle(speculation: id)
                return sentence
            } catch { await self?.settle(speculation: id); throw error }
        }
        speculation = Speculation(id: id, raw: raw, textBefore: before, task: task)
        return true
    }
    private func settle(speculation id: UUID) { if speculation?.id == id { speculation?.settled = true } }
    /// The speculative request's raw text, while one is running or landed and unused.
    public var speculativeText: String? { speculation?.raw }
    /// The speculative request finished and its result waits for its line.
    public var speculationLanded: Bool { speculation?.settled ?? false }
    public func cancelSpeculation() { speculation?.task.cancel(); speculation = nil }

    /// Drops everything pending: a new keyboard session starts with no context.
    public func reset() {
        cancelSpeculation()
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks = [:]; delivering = false; queue = []; inFlight = []; finished = [:]; known = [:]; firstSequence = nil; nextDelivery = 0
    }

    private func pump() {
        while inFlight.count < concurrency, !queue.isEmpty {
            let line = queue.removeFirst()
            inFlight.insert(line.sequence)
            let previous = known.filter { $0.key < line.sequence }.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.suffix(2).map { $0 }
            let context = DictationCleanupContext(previousLines: previous, textBeforeCursor: line.textBefore, style: style)
            let token = generation
            let waited = line.enqueued.duration(to: .now).components
            let queueWaitMs = Int(waited.seconds * 1000 + waited.attoseconds / 1_000_000_000_000_000)
            // A speculative request for exactly this text (and context) is this line's call; any other is stale.
            var spec: Speculation?
            if let held = speculation {
                if held.raw == line.raw, held.textBefore == line.textBefore { spec = held; speculation = nil } else { cancelSpeculation() }
            }
            let input = SentenceCleanupInput(sentenceID: line.lineID, sequence: line.sequence, text: line.raw, vocabulary: vocabulary, dictation: context)
            tasks[line.sequence] = Task { [cleaner, timeout, spec] in
                let outcome = await Self.race(cleaner: cleaner, timeout: timeout, input: input, speculative: spec?.task)
                await self.complete(line, outcome: outcome, generation: token, queueWaitMs: queueWaitMs,
                                    speculation: spec.map { $0.settled ? "landed" : "inflight" })
            }
        }
    }

    private enum Outcome { case cleaned(String, CleanupMetrics?), failed(String), timedOut }
    private static func describe(_ error: any Error) -> String {
        if let known = error as? SentenceCleanupError { return "\(known)" }
        return String(describing: type(of: error)) + ((error as NSError).code != 0 ? "#\((error as NSError).code)" : "")
    }
    private static func race(cleaner: any SentenceCleaning, timeout: Duration, input: SentenceCleanupInput,
                             speculative: Task<ValidatedSentence, any Error>? = nil) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    if let speculative {
                        // The speculative request is awaited, not restarted; if it failed the line is cleaned afresh.
                        let result = await withTaskCancellationHandler { await speculative.result } onCancel: { speculative.cancel() }
                        if case .success(let sentence) = result { return .cleaned(sentence.text, sentence.metrics) }
                        try Task.checkCancellation()
                    }
                    let sentence = try await cleaner.clean(input)
                    return .cleaned(sentence.text, sentence.metrics)
                } catch { return .failed(Self.describe(error)) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .failed("none")
            group.cancelAll()
            return first
        }
    }

    private func complete(_ line: Pending, outcome: Outcome, generation token: UUID, queueWaitMs: Int? = nil, speculation: String? = nil) async {
        guard token == generation else { return }
        tasks[line.sequence] = nil; inFlight.remove(line.sequence)
        var result = DictationCleanedLine(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: nil)
        switch outcome {
        case .cleaned(let text, _) where !line.allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains(where: \.isNewline):
            result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "failed", detail: "\(SentenceCleanupError.invalidText)")
        case .cleaned(let text, _) where DictationCleanupGuard.accepts(raw: line.raw, cleaned: text, style: style):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains(where: \.isNewline) ? "" : text
            result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: text, status: .cleaned, reason: nil)
        case .cleaned: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "rejected")
        case .timedOut: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "timeout")
        case .failed(let detail): result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "failed", detail: detail)
        }
        if case .cleaned(_, let metrics) = outcome { result.metrics = metrics }
        result.queueWaitMs = queueWaitMs; result.speculation = speculation
        known[line.sequence] = result.text
        finished[line.sequence] = result
        pump()
        // One delivery loop at a time: a later line never overtakes an earlier one awaiting `deliver`.
        guard !delivering else { return }
        delivering = true; defer { delivering = false }
        while token == generation, let next = finished.removeValue(forKey: nextDelivery) {
            nextDelivery += 1
            await deliver(next)
        }
    }
}
