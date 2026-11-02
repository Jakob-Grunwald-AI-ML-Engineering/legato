import Foundation
import LegatoClaude

/// What the whole-take cleanup sees: the take's lines joined in speaking order, the field's text at take start
/// and the chunks already sent earlier in this session.
public struct DictationTakeInput: Sendable, Equatable {
    public var takeID: String
    public var text: String
    public var vocabulary: [String]
    public var previousChunks: [String]
    public var textBeforeCursor: String
    public init(takeID: String, text: String, vocabulary: [String] = [], previousChunks: [String] = [], textBeforeCursor: String = "") {
        self.takeID = takeID; self.text = text; self.vocabulary = vocabulary
        self.previousChunks = previousChunks; self.textBeforeCursor = textBeforeCursor
    }
}

/// Time and token budgets that grow with the length of the take.
public enum DictationTakeLimits {
    /// 4 s plus 1 s per 200 characters, at most 20 s.
    public static func timeout(characters: Int) -> Duration {
        .seconds(min(20, 4 + max(0, characters) / 200))
    }
    /// Output is about the input's length: roughly one token per 2 characters is generous for German, with room
    /// for line breaks; never below 1024, never above 16 000.
    public static func maxTokens(characters: Int) -> Int {
        min(16_000, max(1024, max(0, characters) / 2 + 512))
    }
}

/// Sanity checks on a take's cleanup result, scaled for long text. Cleanup keeps the speaker's words in order and
/// only punctuates, recases, drops fillers and duplicates and fixes sounds, so the result stays close in length
/// and made of the words that were said; an answer, an expansion or a rewrite fails it and the raw text stays.
public enum DictationTakeGuard {
    public static func accepts(raw: String, cleaned: String) -> Bool {
        let source = tokens(raw), result = tokens(cleaned)
        // Short takes: the per-line limits fit.
        guard source.count > 12 else { return DictationCleanupGuard.accepts(raw: raw, cleaned: cleaned) }
        guard !cleaned.isEmpty, cleaned.count <= raw.count * 3 / 2 + 64 else { return false }
        // Fillers, duplicates and spoken commands drop words; ASR fixes and splits may add a few.
        guard result.count <= source.count + max(8, source.count / 10), result.count * 10 >= source.count * 4 else { return false }
        let said = Set(source)
        let known = result.filter { said.contains($0) }.count
        return known * 10 >= result.count * 7
    }
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

public enum DictationTakeCleanupResult: Sendable, Equatable {
    case cleaned(String)
    /// Both attempts failed, timed out or were rejected; `reason` names the last (`failed`, `timeout`, `rejected`).
    case failed(reason: String)
    /// No Claude key: nothing to retry, the raw text goes in as heard.
    case unavailable
}

/// Cleans a whole take with one call, retrying once when the call fails, times out or its result is rejected.
public struct DictationTakeCleaner: Sendable {
    private let cleaner: any SentenceCleaning
    private let timeout: @Sendable (Int) -> Duration
    public init(cleaner: any SentenceCleaning,
                timeout: @escaping @Sendable (Int) -> Duration = { DictationTakeLimits.timeout(characters: $0) }) {
        self.cleaner = cleaner; self.timeout = timeout
    }

    public func clean(_ input: DictationTakeInput) async -> DictationTakeCleanupResult {
        var reason = "failed"
        for _ in 0..<2 {
            if Task.isCancelled { break }
            switch await attempt(input) {
            case .cleaned(let text) where DictationTakeGuard.accepts(raw: input.text, cleaned: text): return .cleaned(text)
            case .cleaned: reason = "rejected"
            case .failed(let why): reason = why
            case .unavailable: return .unavailable
            }
        }
        return .failed(reason: reason)
    }

    private enum Outcome { case cleaned(String), failed(String), unavailable }
    private func attempt(_ input: DictationTakeInput) async -> Outcome {
        let limit = timeout(input.text.count), cleaner = self.cleaner
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { return .cleaned(try await cleaner.cleanTake(input)) }
                catch MessagesStreamError.missingKey { return .unavailable }
                catch { return .failed("failed") }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .failed("timeout")
            }
            let first = await group.next() ?? .failed("failed")
            group.cancelAll()
            return first
        }
    }
}
