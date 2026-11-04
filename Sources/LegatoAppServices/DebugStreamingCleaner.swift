#if DEBUG || LEGATO_INTERNAL
import Foundation
import LegatoAgent

/// Debug bridge: a scripted streaming cleaner. It "cleans" a take by capitalizing it and yields the result in small
/// chunks with a delay between them; optionally the first stream fails after `failAfterChunks` chunks (later ones succeed).
/// With `reply` every take streams that text instead, to stand in for a model that answers with something else.
public final class DebugStreamingCleaner: SentenceCleaning, @unchecked Sendable {
    public let chunkDelay: Duration
    public let chunkSize: Int
    private let lock = NSLock()
    private var failAfter: Int?
    private let reply: String?

    public init(chunkMilliseconds: Int, failAfterChunks: Int? = nil, chunkSize: Int = 6, reply: String? = nil) {
        self.reply = reply
        chunkDelay = .milliseconds(max(0, chunkMilliseconds)); self.failAfter = failAfterChunks; self.chunkSize = max(1, chunkSize)
    }

    public func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence { throw SentenceCleanupError.invalidInput }
    public func cleanTake(_ input: DictationTakeInput) async throws -> String { input.text.capitalized }

    public func cleanTakeStream(_ input: DictationTakeInput) -> AsyncThrowingStream<String, any Error> {
        let fail = lock.withLock { () -> Int? in let n = failAfter; failAfter = nil; return n }
        let characters = Array(reply ?? input.text.capitalized)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var sent = 0
                var index = 0
                while index < characters.count {
                    if let fail, sent >= fail { continuation.finish(throwing: SentenceCleanupError.providerError); return }
                    try? await Task.sleep(for: chunkDelay)
                    if Task.isCancelled { return }
                    let end = min(characters.count, index + chunkSize)
                    continuation.yield(String(characters[index..<end]))
                    index = end; sent += 1
                }
                if let fail, sent <= fail, fail > 0, sent == fail { continuation.finish(throwing: SentenceCleanupError.providerError); return }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
