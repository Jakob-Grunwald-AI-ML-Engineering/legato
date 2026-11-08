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
}

/// Cheap sanity checks on a cleanup result. Cleanup only punctuates, recases, drops fillers and fixes sounds, so
/// the result keeps the raw line's words in order; anything that looks like an answer, an expansion or a rewrite
/// is dropped for the raw line.
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
        return source.count <= droppableWords || source.allSatisfy(fillers.contains)
    }

    public static func accepts(raw: String, cleaned: String) -> Bool {
        let source = tokens(raw), result = tokens(cleaned)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cleaned.contains(where: \.isNewline) { return acceptsDrop(raw: raw) }
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
    private static func tokens(_ text: String) -> [String] {
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

/// Cleans dictated lines one call each, at most two in flight, and hands them on strictly in speaking order.
/// A line whose call fails, is rejected by the guard or takes longer than `timeout` goes on raw: dictation never
/// waits on the model beyond that.
public actor DictationCleanupPipeline {
    private struct Pending { let sequence: Int; let lineID: String; let raw: String; let textBefore: String; let allowsEmpty: Bool }
    private let cleaner: any SentenceCleaning
    private let vocabulary: [String]
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

    public init(cleaner: any SentenceCleaning, vocabulary: [String] = [], timeout: Duration = .milliseconds(2500), concurrency: Int = 2,
                deliver: @escaping @Sendable (DictationCleanedLine) async -> Void) {
        self.cleaner = cleaner
        self.vocabulary = Array(vocabulary.prefix(200))
        self.timeout = timeout; self.concurrency = max(1, min(2, concurrency)); self.deliver = deliver
    }

    public var inFlightCount: Int { inFlight.count }

    public func warm() async { await cleaner.warmDictation() }

    /// `textBefore`: the field's text before the cursor now (`documentContextBeforeInput`). `allowsEmpty`: the caller
    /// can drop the line, so an empty result the guard accepts is delivered as cleaned empty text; otherwise an empty
    /// result is a failure (`invalidText`) and the raw line goes on.
    public func submit(sequence: Int, lineID: String, raw: String, textBefore: String, allowsEmpty: Bool = false) async {
        // Lines that never came here (another send mode took them) leave a gap: with nothing waiting, start at this one.
        if firstSequence == nil || (queue.isEmpty && inFlight.isEmpty && finished.isEmpty && sequence != nextDelivery) {
            firstSequence = firstSequence ?? sequence; nextDelivery = sequence
        }
        known[sequence] = raw
        queue.append(Pending(sequence: sequence, lineID: lineID, raw: raw, textBefore: String(textBefore.suffix(600)), allowsEmpty: allowsEmpty))
        queue.sort { $0.sequence < $1.sequence }
        pump()
    }

    /// Drops everything pending: a new keyboard session starts with no context.
    public func reset() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks = [:]; delivering = false; queue = []; inFlight = []; finished = [:]; known = [:]; firstSequence = nil; nextDelivery = 0
    }

    private func pump() {
        while inFlight.count < concurrency, !queue.isEmpty {
            let line = queue.removeFirst()
            inFlight.insert(line.sequence)
            let previous = known.filter { $0.key < line.sequence }.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isEmpty }.suffix(2).map { $0 }
            let context = DictationCleanupContext(previousLines: previous, textBeforeCursor: line.textBefore)
            let token = generation
            tasks[line.sequence] = Task { [cleaner, vocabulary, timeout] in
                let outcome = await Self.race(cleaner: cleaner, timeout: timeout, input: .init(
                    sentenceID: line.lineID, sequence: line.sequence, text: line.raw, vocabulary: vocabulary, dictation: context))
                await self.complete(line, outcome: outcome, generation: token)
            }
        }
    }

    private enum Outcome { case cleaned(String), failed(String), timedOut }
    private static func describe(_ error: any Error) -> String {
        if let known = error as? SentenceCleanupError { return "\(known)" }
        return String(describing: type(of: error)) + ((error as NSError).code != 0 ? "#\((error as NSError).code)" : "")
    }
    private static func race(cleaner: any SentenceCleaning, timeout: Duration, input: SentenceCleanupInput) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .cleaned(try await cleaner.clean(input).text) } catch { return .failed(Self.describe(error)) }
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

    private func complete(_ line: Pending, outcome: Outcome, generation token: UUID) async {
        guard token == generation else { return }
        tasks[line.sequence] = nil; inFlight.remove(line.sequence)
        var result = DictationCleanedLine(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: nil)
        switch outcome {
        case .cleaned(let text) where !line.allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains(where: \.isNewline):
            result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "failed", detail: "\(SentenceCleanupError.invalidText)")
        case .cleaned(let text) where DictationCleanupGuard.accepts(raw: line.raw, cleaned: text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !text.contains(where: \.isNewline) ? "" : text
            result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: text, status: .cleaned, reason: nil)
        case .cleaned: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "rejected")
        case .timedOut: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "timeout")
        case .failed(let detail): result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "failed", detail: detail)
        }
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
