import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoComposerDoc
import LegatoKeyboardCore
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

extension DictationPipelineTests {
    @Test func lineByLineDeliversAfterLinesWentToAnotherSendMode() async throws {
        nonisolated(unsafe) var mode = DictationSendSetting.Mode.lineByLine
        let pipeline = DictationPipeline(cleaner: StubCleaner(), sendMode: { mode })
        await pipeline.receive(routeLine(0, "first"))
        try await until { pipeline.outbox.count == 1 }
        mode = .onStop // the route keeps counting lines the cleanup pipeline never sees
        await pipeline.receive(routeLine(1, "held"))
        await pipeline.receive(routeLine(2, "held too"))
        mode = .lineByLine
        await pipeline.receive(routeLine(3, "fourth"))
        try await until { pipeline.outbox.contains { $0.sequence == 3 } }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveDictationPipelineTests {
    private func live(_ cleaner: StubCleaner = StubCleaner(), supportsLive: Bool = true, timeout: Duration = .milliseconds(200)) -> DictationPipeline {
        DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: supportsLive, liveTimeout: timeout)
    }

    @Test func theTargetIsRawFinalsThenTheHeadAndCleanedSentencesReplaceTheirRawWords() async throws {
        let cleaner = StubCleaner(slow: [0])
        let pipeline = live(cleaner)
        var published: [LiveDictationSnapshot?] = []
        pipeline.onLiveChange = { published.append($0) }
        pipeline.tailChanged("hello wor")
        await pipeline.receive(routeLine(0, "hello world"))
        pipeline.tailChanged("and then")
        let run = try #require(pipeline.liveRun)
        #expect(run.snapshot.segments == [.init(id: 0, text: "hello world", final: true), .init(id: 1, text: "and then", final: false)])
        // Sentence 1 is cleaned first (sentence 0 is slow); both land as replacements of the raw words.
        await pipeline.receive(routeLine(1, "second one"))
        try await until { pipeline.liveRun?.snapshot.segments.contains { $0.cleaned } == true }
        #expect(pipeline.liveRun?.snapshot.segments.first { $0.id == 1 }?.text == "Second One.")
        #expect(pipeline.outbox.isEmpty, "Live never uses the line outbox")
        #expect(published.compactMap { $0?.version } == published.compactMap { $0?.version }.sorted())
    }

    @Test func finishingWaitsForCleanupAndCompletesTheRun() async throws {
        let pipeline = live()
        await pipeline.receive(routeLine(0, "only sentence"))
        await pipeline.finishTake()
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.complete && snapshot.segments == [.init(id: 0, text: "Only Sentence.", cleaned: true, final: true)])
        // The next words start a new run.
        pipeline.tailChanged("again")
        #expect(pipeline.liveRun?.runID != snapshot.runID && pipeline.liveRun?.complete == false)
    }

    @Test func aFailedCleanupLeavesTheRawWordsAndResetClearsTheRun() async throws {
        let pipeline = live(StubCleaner(slow: [0]), timeout: .milliseconds(30))
        var last: LiveDictationSnapshot?? = .none
        pipeline.onLiveChange = { last = .some($0) }
        await pipeline.receive(routeLine(0, "slow words"))
        try await until { pipeline.fallbacks == ["timeout"] }
        #expect(pipeline.liveRun?.snapshot.segments == [.init(id: 0, text: "slow words", final: true)])
        await pipeline.reset()
        #expect(pipeline.liveRun == nil)
        #expect(last == .some(nil), "The link's run is removed")
    }

    @Test func switchingFromLiveToLineByLineKeepsDeliveringLines() async throws {
        nonisolated(unsafe) var mode = DictationSendSetting.Mode.live
        let pipeline = DictationPipeline(cleaner: StubCleaner(), sendMode: { mode }, supportsLive: true, liveTimeout: .milliseconds(200))
        await pipeline.receive(routeLine(0, "first"))
        await pipeline.receive(routeLine(1, "second"))
        try await until { pipeline.liveRun?.snapshot.segments.allSatisfy { $0.cleaned } == true }
        mode = .lineByLine
        await pipeline.receive(routeLine(2, "third"))
        try await until { pipeline.outbox.count == 1 }
        #expect(pipeline.outbox[0].sequence == 2 && pipeline.outbox[0].text == "Third.")
    }

    @Test func sentencesAreCleanedAgainstTheTextBeforeTheRunNotTheFieldTheRunIsTyping() async throws {
        let cleaner = StubCleaner(slow: [0])
        let pipeline = live(cleaner)
        nonisolated(unsafe) var field = "Hi Anna,"
        pipeline.contextBefore = { field }
        await pipeline.receive(routeLine(0, "hello world"))
        field = "Hi Anna, hello world and then it" // the keyboard has typed the run's words into the field
        await pipeline.receive(routeLine(1, "second one"))
        try await until { cleaner.inputs.withLock { $0.count } == 2 }
        let inputs = cleaner.inputs.withLock { $0 }
        #expect(inputs.first { $0.sequence == 0 }?.dictation?.textBeforeCursor == "Hi Anna,")
        #expect(inputs.first { $0.sequence == 1 }?.dictation?.textBeforeCursor == "Hi Anna, hello world")
    }

    @Test func withoutLiveSupportTheSettingActsAsOnStop() async {
        let pipeline = live(supportsLive: false)
        #expect(pipeline.mode == .onStop)
        await pipeline.receive(routeLine(0, "held"))
        #expect(pipeline.liveRun == nil && pipeline.takeLines == ["held"])
    }
}
