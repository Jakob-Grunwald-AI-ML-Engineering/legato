import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoComposerDoc
@testable import LegatoAppServices

private final class StubCleaner: SentenceCleaning {
    let inputs = Mutex<[SentenceCleanupInput]>([])
    let warms = Mutex(0)
    let slow: Set<Int>
    init(slow: Set<Int> = []) { self.slow = slow }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        inputs.withLock { $0.append(input) }
        if slow.contains(input.sequence) { try await Task.sleep(for: .seconds(10)) }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text.capitalized + ".")
    }
    func warmDictation() async { warms.withLock { $0 += 1 } }
}
private func routeLine(_ sequence: Int, _ text: String) -> DictationRouteLine {
    .init(sequence: sequence, text: text, words: text.split(separator: " ").map { Word(text: String($0)) }, reason: "endpoint")
}
@MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for condition")
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationPipelineTests {
    @Test func cleanedLinesWaitInTheOutboxUntilAcknowledgedAndNeverReturn() async throws {
        let pipeline = DictationPipeline(cleaner: StubCleaner())
        var changes = 0
        pipeline.onChange = { changes += 1 }
        await pipeline.receive(routeLine(0, "hello there"))
        await pipeline.receive(routeLine(1, "second one"))
        try await until { pipeline.outbox.count == 2 }
        #expect(pipeline.outbox.map(\.text) == ["Hello There.", "Second One."])
        #expect(pipeline.outbox.map(\.sequence) == [0, 1] && pipeline.outbox.allSatisfy(\.cleaned))
        let session = pipeline.sessionID

        pipeline.acknowledge(sessionID: "another-session", upTo: 5)
        #expect(pipeline.outbox.count == 2, "An ack for another session changes nothing")
        pipeline.acknowledge(sessionID: session, upTo: 0)
        #expect(pipeline.outbox.map(\.sequence) == [1])
        pipeline.acknowledge(sessionID: session, upTo: 0)
        pipeline.acknowledge(sessionID: session, upTo: 1)
        #expect(pipeline.outbox.isEmpty && changes >= 4)
    }

    @Test func aSlowCleanupFallsBackToTheRawLineAndTheContextIsThePresenceText() async throws {
        let cleaner = StubCleaner(slow: [0])
        let pipeline = DictationPipeline(cleaner: cleaner, vocabulary: { ["Legato"] }, timeout: .milliseconds(40))
        pipeline.contextBefore = { "Hi Anna, " }
        await pipeline.receive(routeLine(0, "uh i am late"))
        await pipeline.receive(routeLine(1, "see you soon"))
        try await until { pipeline.outbox.count == 2 }
        #expect(pipeline.outbox[0].text == "uh i am late" && !pipeline.outbox[0].cleaned, "Timeout: the raw line, in order")
        #expect(pipeline.outbox[1].cleaned)
        #expect(pipeline.fallbacks == ["timeout"])
        let first = cleaner.inputs.withLock { $0 }.first { $0.sequence == 0 }
        #expect(first?.dictation?.textBeforeCursor == "Hi Anna, " && first?.vocabulary == ["Legato"])
    }

    @Test func resetStartsANewSessionWithoutContextAndDropsPendingLines() async throws {
        let cleaner = StubCleaner(slow: [0])
        let pipeline = DictationPipeline(cleaner: cleaner)
        let before = pipeline.sessionID
        await pipeline.receive(routeLine(0, "never arrives"))
        await pipeline.reset()
        #expect(pipeline.sessionID != before && pipeline.outbox.isEmpty)
        await pipeline.receive(routeLine(0, "fresh start"))
        try await until { pipeline.outbox.count == 1 }
        #expect(pipeline.outbox[0].lineID.hasPrefix(pipeline.sessionID))
        let last = cleaner.inputs.withLock { $0 }.last
        #expect(last?.dictation?.previousLines == [], "Cleanup context is reset per keyboard session")
    }

    @Test func warmingIsThrottledToTheCacheLifetime() async {
        let cleaner = StubCleaner()
        let pipeline = DictationPipeline(cleaner: cleaner)
        await pipeline.warm(); await pipeline.warm()
        #expect(cleaner.warms.withLock { $0 } == 1)
        await pipeline.reset()
        await pipeline.warm()
        #expect(cleaner.warms.withLock { $0 } == 2, "A new keyboard session warms again")
    }
}
