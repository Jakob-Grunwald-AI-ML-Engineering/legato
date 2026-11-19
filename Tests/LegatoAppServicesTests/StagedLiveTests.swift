import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoComposerDoc
import LegatoCore
import LegatoKeyboardCore
@testable import LegatoAppServices

private final class Upper: SentenceCleaning {
    let inputs = Mutex<[String]>([])
    let slow: Set<String>
    init(slow: Set<String> = []) { self.slow = slow }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        inputs.withLock { $0.append(input.text) }
        if slow.contains(input.text) { try await Task.sleep(for: .seconds(10)) }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text.prefix(1).uppercased() + input.text.dropFirst())
    }
}
private func line(_ sequence: Int, _ text: String) -> DictationRouteLine {
    .init(sequence: sequence, text: text, words: text.split(separator: " ").map { Word(text: String($0)) }, reason: "endpoint")
}
@MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    if !condition() { Issue.record("Timed out waiting for condition") }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct StagedLiveTests {
    private func staged(_ cleaner: any SentenceCleaning, timeout: Duration = .milliseconds(200)) -> DictationPipeline {
        DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: timeout, stagedLive: true)
    }

    @Test func aPauseClosesTheOpenUnitEarlyAndItsCleanedTextIsPublishedWhileTheTakeGoesOn() async throws {
        let cleaner = Upper()
        let pipeline = staged(cleaner)
        await pipeline.receive(line(0, "ship it friday"))
        #expect(cleaner.inputs.withLock { $0.isEmpty }, "A short unit waits for its sentence end")
        pipeline.boundary("endpoint")
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.staged == true && !snapshot.complete)
        #expect(snapshot.segments.first == .init(id: 0, text: "Ship it friday", cleaned: true, final: true, ready: true))
        // The next words open a new unit.
        await pipeline.receive(line(1, "and the budget"))
        #expect(pipeline.liveRun?.snapshot.segments.map(\.id) == [0, 1])
    }

    @Test func theStopClosesTheOpenUnitAndEveryUnitIsReadyWhenTheTakeEnds() async throws {
        let cleaner = Upper()
        let pipeline = staged(cleaner)
        await pipeline.receive(line(0, "we should ship it on friday."))
        await pipeline.receive(line(1, "uh and the budget"))
        await pipeline.finishTake()
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.complete)
        #expect(snapshot.segments.map(\.text) == ["We should ship it on friday.", "Uh and the budget"])
        #expect(snapshot.segments.allSatisfy { $0.ready == true && $0.cleaned })
        #expect(cleaner.inputs.withLock { $0.count } == 2, "No whole-take pass: typed units are never replaced")
    }

    @Test func aCleanupThatRunsOutOfTimeIsTypedAsItsRawWords() async throws {
        let cleaner = Upper(slow: ["this one never comes back in time."])
        let pipeline = staged(cleaner)
        await pipeline.receive(line(0, "this one never comes back in time."))
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        let segment = try #require(pipeline.liveRun?.snapshot.segments.first)
        #expect(segment.text == "this one never comes back in time." && !segment.cleaned)
        pipeline.boundary("finalize")
        await pipeline.reset()
    }
}
