import Foundation
import LegatoRoom
import LegatoComposerDoc

public struct SentencePipelineStatus: Sendable {
    public let pending: Int
    public let inFlight: Int
    public let failed: Bool
    public let message: String?
}
/// Independent copyediting jobs may overlap the sole document writer. Only this
/// ordered handoff reaches the binder; a job never gets a Room/document tool.
public actor OrderedSentencePipeline {
    private struct Entry { let sentence: DictationSentence; var attempts = 0 }
    private let cleaner: any SentenceCleaning
    private let vocabulary: [String]
    private let accept: @Sendable (ValidatedDictation) async throws -> Void
    private let diagnostic: @Sendable ([String: JSONValue]) async -> Void
    private let status: @Sendable (SentencePipelineStatus) async -> Void
    private let concurrency: Int
    private let capacity: Int
    private var generation = UUID()
    private var entries: [Int: Entry] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var ready: [Int: ValidatedSentence] = [:]
    private var failed: Set<Int> = []
    private var failures: [Int: SentenceCleanupFailure] = [:]
    private var seen: Set<String> = []
    private var nextAdmission = 0
    private var admitting = false
    private var canceled = false
    public init(cleaner: any SentenceCleaning, vocabulary: [String] = [], concurrency: Int = 2, capacity: Int = 32,
                accept: @escaping @Sendable (ValidatedDictation) async throws -> Void,
                status: @escaping @Sendable (SentencePipelineStatus) async -> Void = { _ in },
                diagnostic: @escaping @Sendable ([String: JSONValue]) async -> Void = { _ in }) {
        self.cleaner = cleaner
        var vocabularyBytes = 0
        self.vocabulary = vocabulary.prefix(200).filter { term in
            guard !term.isEmpty, vocabularyBytes + term.utf8.count <= 16_384 else { return false }
            vocabularyBytes += term.utf8.count; return true
        }
        self.accept = accept; self.status = status; self.diagnostic = diagnostic
        self.concurrency = max(1, min(2, concurrency)); self.capacity = max(2, capacity)
    }
    public var hasFailure: Bool { !failed.isEmpty }
    public var pendingCount: Int { entries.count }
    public func enqueue(_ sentence: DictationSentence) async {
        let token = generation
        guard !canceled, !seen.contains(sentence.id) else { return }
        // Bound retained work and provider requests. The binder's inbox supplies
        // backpressure rather than dropping a sentence or bypassing validation.
        if entries.count >= capacity { await report(message: "Sentence cleanup is catching up. Pending speech is kept.") }
        while entries.count >= capacity {
            try? await Task.sleep(for: .milliseconds(30))
            guard token == generation, !canceled, !Task.isCancelled else { return }
        }
        guard token == generation, !canceled, entries[sentence.sequence] == nil else { return }
        seen.insert(sentence.id); entries[sentence.sequence] = Entry(sentence: sentence)
        await pump()
    }
    private func pump() async {
        guard !canceled else { return }
        await admitReady()
        guard failed.isEmpty else { await report(); return }
        for sequence in entries.keys.sorted() where tasks.count < concurrency {
            guard var entry = entries[sequence], tasks[sequence] == nil, ready[sequence] == nil else { continue }
            entry.attempts += 1; entries[sequence] = entry
            let attempt = entry.attempts, wordCount = entry.sentence.words.count
            let token = generation, input = SentenceCleanupInput(sentenceID: entry.sentence.id, sequence: sequence, text: entry.sentence.text, vocabulary: vocabulary)
            tasks[sequence] = Task { [weak self, cleaner, diagnostic] in
                await diagnostic(["event": .string("sentence.request"), "sentenceID": .string(input.sentenceID), "sequence": .number(Double(sequence)), "model": .string(ModelChoice.haiku.rawValue), "attempt": .number(Double(attempt)), "inputBytes": .number(Double(input.text.utf8.count)), "wordCount": .number(Double(wordCount))])
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try await cleaner.clean(input)
                    await diagnostic(["event": .string("sentence.response"), "sentenceID": .string(input.sentenceID), "sequence": .number(Double(sequence)), "seconds": .number(ProcessInfo.processInfo.systemUptime - started), "ok": .bool(true)])
                    await self?.completed(result, sequence: sequence, generation: token)
                } catch {
                    let cause = SentenceCleanupFailure.classify(error)
                    var fields: [String: JSONValue] = ["event": .string("sentence.response"), "sentenceID": .string(input.sentenceID), "sequence": .number(Double(sequence)), "seconds": .number(ProcessInfo.processInfo.systemUptime - started), "ok": .bool(false), "attempt": .number(Double(attempt))]
                    fields.merge(cause.fields) { _, new in new }
                    await diagnostic(fields)
                    await self?.failure(sequence: sequence, generation: token, cause: cause)
                }
            }
        }
        await report()
    }
    private func completed(_ result: ValidatedSentence, sequence: Int, generation token: UUID) async {
        guard token == generation, !canceled, let entry = entries[sequence] else { return }
        tasks[sequence] = nil
        guard result.sentenceID == entry.sentence.id, result.sequence == sequence,
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.text.count <= max(256, entry.sentence.text.count * 4) else {
            let cause = SentenceCleanupFailure(code: "invalid_handoff", stage: "validation", summary: "response failed handoff validation")
            var fields: [String: JSONValue] = ["event": .string("sentence.validation.failed"), "sequence": .number(Double(sequence))]
            fields.merge(cause.fields) { _, new in new }; await diagnostic(fields)
            await failure(sequence: sequence, generation: token, cause: cause); return
        }
        ready[sequence] = result
        await pump()
    }
    private func failure(sequence: Int, generation token: UUID, cause: SentenceCleanupFailure) async {
        guard token == generation, !canceled, entries[sequence] != nil else { return }
        tasks[sequence] = nil; failed.insert(sequence); failures[sequence] = cause
        await report()
    }
    private func admitReady() async {
        guard !admitting else { return }
        admitting = true; defer { admitting = false }
        let token = generation
        while !canceled, token == generation, !failed.contains(nextAdmission),
              let result = ready[nextAdmission], let entry = entries[nextAdmission] {
            let words = Self.validatedWords(result.text, source: entry.sentence.words)
            do {
                try await accept(.init(sentenceID: result.sentenceID, sequence: result.sequence, words: words, sourceWordIDs: entry.sentence.words.map(\.id), continuation: entry.sentence.continuation))
                guard token == generation, !canceled else { return }
                entries[nextAdmission] = nil; ready[nextAdmission] = nil; nextAdmission += 1
            } catch {
                let cause = SentenceCleanupFailure(code: "admission_failed", stage: "admission", summary: "validated sentence could not enter the draft")
                failed.insert(nextAdmission); failures[nextAdmission] = cause
                var fields: [String: JSONValue] = ["event": .string("sentence.admission.failed"), "sequence": .number(Double(nextAdmission))]
                fields.merge(cause.fields) { _, new in new }; await diagnostic(fields)
                return
            }
        }
    }
    /// One explicit retry per failed sentence; repeated failures never create an automatic request loop.
    public func retryFailed() async {
        for sequence in failed where (entries[sequence]?.attempts ?? 2) < 2 { failed.remove(sequence); failures[sequence] = nil }
        await pump()
    }
    public func cancel() async {
        canceled = true; generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks = [:]; entries = [:]; ready = [:]; failed = []; failures = [:]
        await report()
    }
    private func report(message: String? = nil) async {
        let reason = failed.sorted().first.flatMap { failures[$0]?.summary } ?? "unknown cause"
        await status(.init(pending: entries.count, inFlight: tasks.count, failed: !failed.isEmpty,
            message: failed.isEmpty ? message : (failed.contains(where: { (entries[$0]?.attempts ?? 0) >= 2 })
                ? "Sentence cleanup failed again (\(reason)). Pending speech is kept; Clear or New topic discards it."
                : "Sentence cleanup failed (\(reason)). Pending speech is kept. Pause, then tap the microphone to retry.")))
    }
    /// Exact unchanged tokens retain acoustic metadata and IDs. Changed/new tokens
    /// get new IDs and no invented confidence, while the handoff keeps source IDs.
    static func validatedWords(_ text: String, source: [Word]) -> [Word] {
        var cursor = 0
        return text.split(whereSeparator: \.isWhitespace).map { token in
            let value = String(token)
            if let match = source.indices.dropFirst(cursor).first(where: { source[$0].text == value }) {
                cursor = match + 1; return source[match]
            }
            return Word(text: value, language: source.first?.language)
        }
    }
}
