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
}

/// Cheap sanity checks on a cleanup result. Cleanup only punctuates, recases, drops fillers and fixes sounds, so
/// the result keeps the raw line's words in order; anything that looks like an answer, an expansion or a rewrite
/// is dropped for the raw line.
public enum DictationCleanupGuard {
    public static func accepts(raw: String, cleaned: String) -> Bool {
        let source = tokens(raw), result = tokens(cleaned)
        guard !cleaned.isEmpty, cleaned.count <= max(48, raw.count * 3 / 2 + 24) else { return false }
        if result.isEmpty { return true } // a bare line break or punctuation from a spoken command
        guard source.count > 3 else { return result.count <= source.count + 3 }
        guard result.count <= source.count + 4, result.count * 5 >= source.count * 2 else { return false }
        // Most of the result's words must be words the speaker said (ASR fixes and spoken commands may differ).
        let said = Set(source)
        let known = result.filter { said.contains($0) }.count
        return known * 2 >= result.count
    }
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Cleans dictated lines one call each, at most two in flight, and hands them on strictly in speaking order.
/// A line whose call fails, is rejected by the guard or takes longer than `timeout` goes on raw: dictation never
/// waits on the model beyond that.
public actor DictationCleanupPipeline {
    private struct Pending { let sequence: Int; let lineID: String; let raw: String; let textBefore: String }
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

    /// `textBefore`: the field's text before the cursor now (`documentContextBeforeInput`).
    public func submit(sequence: Int, lineID: String, raw: String, textBefore: String) async {
        if firstSequence == nil { firstSequence = sequence; nextDelivery = sequence }
        known[sequence] = raw
        queue.append(Pending(sequence: sequence, lineID: lineID, raw: raw, textBefore: String(textBefore.suffix(600))))
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
            let previous = known.filter { $0.key < line.sequence }.sorted { $0.key < $1.key }.suffix(2).map(\.value)
            let context = DictationCleanupContext(previousLines: previous, textBeforeCursor: line.textBefore)
            let token = generation
            tasks[line.sequence] = Task { [cleaner, vocabulary, timeout] in
                let outcome = await Self.race(cleaner: cleaner, timeout: timeout, input: .init(
                    sentenceID: line.lineID, sequence: line.sequence, text: line.raw, vocabulary: vocabulary, dictation: context))
                await self.complete(line, outcome: outcome, generation: token)
            }
        }
    }

    private enum Outcome { case cleaned(String), failed, timedOut }
    private static func race(cleaner: any SentenceCleaning, timeout: Duration, input: SentenceCleanupInput) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .cleaned(try await cleaner.clean(input).text) } catch { return .failed }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }

    private func complete(_ line: Pending, outcome: Outcome, generation token: UUID) async {
        guard token == generation else { return }
        tasks[line.sequence] = nil; inFlight.remove(line.sequence)
        var result = DictationCleanedLine(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: nil)
        switch outcome {
        case .cleaned(let text) where DictationCleanupGuard.accepts(raw: line.raw, cleaned: text):
            result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: text, status: .cleaned, reason: nil)
        case .cleaned: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "rejected")
        case .timedOut: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "timeout")
        case .failed: result = .init(sequence: line.sequence, lineID: line.lineID, raw: line.raw, text: line.raw, status: .raw, reason: "failed")
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
