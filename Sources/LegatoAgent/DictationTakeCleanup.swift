import Foundation
import LegatoClaude

/// What the whole-take cleanup sees: the take's lines joined in speaking order, the field's text at take start
/// and the recent takes (raw to cleaned) of earlier sessions and this one.
public struct DictationTakeInput: Sendable, Equatable {
    public var takeID: String
    public var text: String
    public var vocabulary: [String]
    /// Earlier cleaned takes, oldest first (see `RecentTakesStore.correctionPairs`).
    public var recentTakes: [RecentTake]
    public var textBeforeCursor: String
    public init(takeID: String, text: String, vocabulary: [String] = [], recentTakes: [RecentTake] = [], textBeforeCursor: String = "") {
        self.takeID = takeID; self.text = text; self.vocabulary = vocabulary
        self.recentTakes = recentTakes; self.textBeforeCursor = textBeforeCursor
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
        // A take is never dropped whole (only a live unit may be).
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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

    /// Cleans the take as a stream: `onDelta` gets each piece of the cleaned text as it arrives. The first attempt
    /// that fails before any piece arrived is retried once, as in `clean`; one that fails after pieces were
    /// handed out is not (the text is partly in the field), it ends as `.failed` and the caller decides. The guard
    /// runs on the finished text only: `rejected` tells the caller to take the streamed text back.
    public func cleanStreaming(_ input: DictationTakeInput, onDelta: @escaping @Sendable (String) async -> Void)
        async -> (result: DictationTakeCleanupResult, rejected: Bool) {
        var reason = "failed"
        for _ in 0..<2 {
            if Task.isCancelled { break }
            let seen = Flag()
            switch await attempt(input, seen: seen, onDelta: onDelta) {
            case .cleaned(let text): return (.cleaned(text), !DictationTakeGuard.accepts(raw: input.text, cleaned: text))
            case .failed(let why):
                reason = why
                if seen.value { return (.failed(reason: reason), false) }
            case .unavailable: return (.unavailable, false)
            }
        }
        return (.failed(reason: reason), false)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        var value: Bool { lock.withLock { set } }
        func raise() { lock.withLock { set = true } }
    }
    private func attempt(_ input: DictationTakeInput, seen: Flag, onDelta: @escaping @Sendable (String) async -> Void) async -> Outcome {
        let limit = timeout(input.text.count), cleaner = self.cleaner
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var text = ""
                do {
                    for try await delta in cleaner.cleanTakeStream(input) where !delta.isEmpty {
                        seen.raise(); text += delta
                        await onDelta(delta)
                    }
                    return .cleaned(text)
                }
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
