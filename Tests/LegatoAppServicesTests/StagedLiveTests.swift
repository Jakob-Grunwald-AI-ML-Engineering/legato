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

    private func manual(_ cleaner: any SentenceCleaning, clock: any Clock<Duration> = ContinuousClock()) -> DictationPipeline {
        DictationPipeline(cleaner: cleaner, sendMode: { .live }, clock: clock, supportsLive: true, liveSend: { .manual },
                          liveTimeout: .milliseconds(200), stagedLive: true)
    }

    @Test func aManualRunIgnoresPausesAndSentenceEndsUntilSendNowFlushesAfterTheFinalizeBoundary() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        await pipeline.receive(line(0, "we should ship it on friday after the review."))
        pipeline.boundary("endpoint")
        // A pause may start a speculative cleanup of the open unit, but nothing is sent or published by it.
        #expect(pipeline.liveRun?.snapshot.segments.first?.ready == false, "Neither a sentence end nor a pause sends in manual mode")
        await pipeline.sendNow()
        #expect(pipeline.liveRun?.snapshot.segments.first?.ready == false, "The unit waits for the finalize boundary")
        // The words the cut made final arrive before the boundary and belong to the sent unit.
        await pipeline.receive(.init(sequence: 1, text: "and the budget", words: [], reason: "finalize"))
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0.last } == "we should ship it on friday after the review. and the budget")
        // Words after the cut start the next unit.
        await pipeline.receive(line(2, "next thing"))
        #expect(pipeline.liveRun?.snapshot.segments.map(\.id) == [0, 2])
        await pipeline.reset()
    }

    @Test func aSpeculativeCleanupAtAPauseIsReusedByTheTapWhenNothingWasAdded() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        var events: [(String, [String: Any])] = []
        pipeline.diagnostics = { event, fields in events.append((event, fields)) }
        await pipeline.receive(line(0, "we should ship it on friday."))
        pipeline.boundary("endpoint")
        try await until { cleaner.inputs.withLock { $0.count } == 1 }
        #expect(pipeline.liveRun?.snapshot.segments.first?.ready == false, "Nothing is published by the speculation")
        await pipeline.sendNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0.count } == 1, "The tap reuses the request")
        #expect(pipeline.liveRun?.snapshot.segments.first?.text == "We should ship it on friday.")
        #expect(events.first { $0.0 == "live2.cleanup" }?.1["speculation"] as? String == "landed")
        await pipeline.reset()
    }

    @Test func aSpeculativeCleanupIsDroppedWhenWordsWereAddedBeforeTheTap() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        var events: [(String, [String: Any])] = []
        pipeline.diagnostics = { event, fields in events.append((event, fields)) }
        await pipeline.receive(line(0, "we should ship it on friday."))
        pipeline.boundary("endpoint")
        try await until { cleaner.inputs.withLock { $0.count } == 1 }
        await pipeline.receive(line(1, "and the budget"))
        await pipeline.sendNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0 } == ["we should ship it on friday.", "we should ship it on friday. and the budget"])
        #expect(pipeline.liveRun?.snapshot.segments.first?.text == "We should ship it on friday. and the budget")
        #expect(events.first { $0.0 == "live2.cleanup" }?.1["speculation"] as? String == "grew")
        await pipeline.reset()
    }

    @Test func shortUnitsAndAutoRunsStartNoSpeculation() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        await pipeline.receive(line(0, "ship it friday"))
        pipeline.boundary("endpoint")
        try await Task.sleep(for: .milliseconds(50))
        #expect(cleaner.inputs.withLock { $0.isEmpty })
        await pipeline.reset()
    }

    @Test func sendNowSendsAfterTheTimeoutWhenNoFinalizeBoundaryComes() async throws {
        let cleaner = Upper()
        let clock = VirtualClock()
        let pipeline = manual(cleaner, clock: clock)
        pipeline.cutRecognizer = { true }
        await pipeline.receive(line(0, "ship it friday"))
        await pipeline.sendNow()
        try await until { clock.sleeperCount > 0 }
        #expect(cleaner.inputs.withLock { $0.isEmpty })
        clock.advance(by: DictationPipeline.sendCutWait)
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0 } == ["ship it friday"])
        await pipeline.reset()
    }

    @Test func sendRawNowPublishesTheOpenAndTheWaitingUnitsRawAndIgnoresTheirLateCleanup() async throws {
        let cleaner = Upper(slow: ["first unit stays slow"])
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        await pipeline.receive(line(0, "first unit stays slow"))
        await pipeline.sendNow()
        pipeline.boundary("finalize")
        try await until { cleaner.inputs.withLock { $0 } == ["first unit stays slow"] }
        await pipeline.receive(line(1, "second unit raw"))
        await pipeline.sendRawNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.allSatisfy { $0.ready == true } == true }
        let segments = try #require(pipeline.liveRun?.snapshot.segments)
        #expect(segments.map(\.text) == ["first unit stays slow", "second unit raw"])
        #expect(cleaner.inputs.withLock { $0 } == ["first unit stays slow"], "The open unit is never sent for cleanup")
        await pipeline.reset()
    }

    @Test func discardNowKeepsTheOpenUnitForTheUndoWindowThenEmptiesItAndNeverCleansIt() async throws {
        let cleaner = Upper()
        let clock = VirtualClock()
        let pipeline = manual(cleaner, clock: clock)
        pipeline.cutRecognizer = { true }
        await pipeline.discardNow()
        #expect(pipeline.liveRun == nil, "Nothing to discard")
        await pipeline.receive(line(0, "never mind all of this"))
        await pipeline.discardNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.discarded == true }
        var unit = try #require(pipeline.liveRun?.snapshot.segments.first)
        #expect(unit.text == "never mind all of this" && unit.closed == true && unit.ready == false)
        try await until { clock.sleeperCount > 0 }
        clock.advance(by: .seconds(DictationPipeline.discardUndoSeconds))
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        unit = try #require(pipeline.liveRun?.snapshot.segments.first)
        #expect(unit.text.isEmpty && unit.discarded == nil)
        #expect(cleaner.inputs.withLock { $0.isEmpty })
        await pipeline.reset()
    }

    @Test func undoDiscardNowCleansTheUnitLikeASend() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        await pipeline.receive(line(0, "bring it back"))
        await pipeline.discardNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.discarded == true }
        await pipeline.undoDiscardNow()
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        let unit = try #require(pipeline.liveRun?.snapshot.segments.first)
        #expect(unit.text == "Bring it back" && unit.discarded == nil)
        #expect(cleaner.inputs.withLock { $0 } == ["bring it back"])
        await pipeline.reset()
    }

    @Test func sendNowSendsAtOnceWhenThereIsNothingToCutAndIsIgnoredWithoutAnOpenUnit() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { false }
        await pipeline.sendNow()
        #expect(pipeline.liveRun == nil)
        await pipeline.receive(line(0, "ship it friday"))
        await pipeline.sendNow()
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0 } == ["ship it friday"])
        await pipeline.reset()
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
        #expect(snapshot.segments.first == .init(id: 0, text: "Ship it friday", cleaned: true, final: true, ready: true, closed: true))
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

    // MARK: Pause (the mic key in manual mode)

    @Test func aPausedManualRunKeepsItsWordsPendingAndTheNextStartAppendsToTheSameUnit() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        pipeline.beginTake()
        await pipeline.receive(line(0, "ship it friday"))
        let runID = try #require(pipeline.liveRun?.runID)
        await pipeline.pauseTake()
        var snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(pipeline.isPaused && snapshot.paused == true && !snapshot.complete)
        #expect(snapshot.segments.map(\.ready) == [false], "Nothing is cleaned or sent by the pause")
        #expect(cleaner.inputs.withLock { $0.isEmpty })
        // The next start continues the run: same id, no new run, and the words join the open unit.
        pipeline.beginTake()
        snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(!pipeline.isPaused && snapshot.paused == nil && snapshot.runID == runID)
        await pipeline.receive(line(1, "and the budget"))
        #expect(pipeline.liveRun?.snapshot.segments.count == 1)
        await pipeline.sendNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0 } == ["ship it friday and the budget"], "Both parts are cleaned as one unit")
        #expect(pipeline.liveRun?.runID == runID && pipeline.liveRun?.complete == false, "The take goes on after the send")
        await pipeline.reset()
    }

    @Test func aTapWhilePausedCleansTheWordsAndEndsTheRun() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { Issue.record("Nothing listens while paused: there is no cut"); return true }
        pipeline.beginTake()
        await pipeline.receive(line(0, "ship it friday"))
        await pipeline.pauseTake()
        await pipeline.sendNow()
        try await until { pipeline.liveRun?.complete == true }
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.segments.map(\.text) == ["Ship it friday"] && snapshot.segments.allSatisfy { $0.ready == true })
        #expect(snapshot.paused == nil && !pipeline.isPaused)
        // The next start is a new run.
        pipeline.beginTake()
        await pipeline.receive(line(1, "next take"))
        #expect(pipeline.liveRun?.runID != snapshot.runID)
        await pipeline.reset()
    }

    @Test func aSwipeWhilePausedInsertsTheWordsRawWithNoCleanup() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.beginTake()
        await pipeline.receive(line(0, "ship it friday"))
        await pipeline.pauseTake()
        await pipeline.sendRawNow()
        try await until { pipeline.liveRun?.complete == true }
        let segment = try #require(pipeline.liveRun?.snapshot.segments.first)
        #expect(segment.text == "ship it friday" && !segment.cleaned && segment.ready == true)
        #expect(cleaner.inputs.withLock { $0.isEmpty })
        await pipeline.reset()
    }

    @Test func theSessionEndingCompletesAPausedRunWithItsWordsCleaned() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.beginTake()
        await pipeline.receive(line(0, "ship it friday"))
        await pipeline.pauseTake()
        await pipeline.finishTake()
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.complete && snapshot.paused == nil && !pipeline.isPaused)
        #expect(snapshot.segments.map(\.text) == ["Ship it friday"], "End of take cleans what was pending, as a Stop does")
        await pipeline.reset()
    }

    @Test func aPauseWithNothingPendingEndsTheTakeLikeAStopAndSentenceModeStopsAsBefore() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { false }
        pipeline.beginTake()
        await pipeline.receive(line(0, "ship it friday"))
        await pipeline.sendNow()
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        await pipeline.pauseTake()
        #expect(pipeline.liveRun?.complete == true && !pipeline.isPaused, "Everything was sent: nothing to hold")
        await pipeline.reset()

        let sentence = staged(Upper())
        sentence.beginTake()
        await sentence.receive(line(0, "ship it friday"))
        await sentence.pauseTake()
        #expect(sentence.liveRun?.complete == true && !sentence.isPaused && sentence.liveRun?.snapshot.paused == nil)
        await sentence.reset()
    }

    @Test func aSpeculativeCleanupStartedAtThePauseIsReusedAfterTheResume() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.cutRecognizer = { true }
        pipeline.beginTake()
        await pipeline.receive(line(0, "we should ship it friday"))
        await pipeline.pauseTake()
        try await until { cleaner.inputs.withLock { $0.count } == 1 }
        pipeline.beginTake()
        await pipeline.sendNow()
        pipeline.boundary("finalize")
        try await until { pipeline.liveRun?.snapshot.segments.first?.ready == true }
        #expect(cleaner.inputs.withLock { $0.count } == 1, "An unchanged text keeps its request across pause and resume")
        await pipeline.reset()
    }

    @Test func aRunTheKeyboardStoppedFollowingIsNeverPausedOrResumed() async throws {
        let cleaner = Upper()
        let pipeline = manual(cleaner)
        pipeline.beginTake()
        await pipeline.receive(line(0, "ship it friday"))
        let runID = try #require(pipeline.liveRun?.runID)
        // The keyboard went to another field before the stop: the stop ends the run.
        pipeline.acknowledgeDelivery(.init(runID: runID, version: 1, stats: .init(), delivered: false, ended: true))
        await pipeline.pauseTake()
        #expect(pipeline.liveRun?.complete == true && !pipeline.isPaused)
        await pipeline.reset()

        // Or while paused: it ends at once.
        pipeline.beginTake()
        await pipeline.receive(line(1, "next thing here"))
        let second = try #require(pipeline.liveRun?.runID)
        await pipeline.pauseTake()
        #expect(pipeline.isPaused)
        pipeline.acknowledgeDelivery(.init(runID: second, version: 1, stats: .init(), delivered: false, ended: true))
        try await until { pipeline.liveRun?.complete == true }
        #expect(!pipeline.isPaused)
        pipeline.beginTake()
        await pipeline.receive(line(2, "third take"))
        #expect(pipeline.liveRun?.runID != second)
        await pipeline.reset()
    }

    /// A session reset that drops a run before it ended says so (`live2.run.drop`): otherwise the run just has no `live2.run.end`.
    @Test func aResetThatDropsAnUnfinishedRunIsLogged() async throws {
        let pipeline = manual(Upper())
        var drops: [[String: Any]] = []
        pipeline.diagnostics = { event, fields in if event == "live2.run.drop" { drops.append(fields) } }
        pipeline.beginTake()
        await pipeline.receive(line(0, "words that wait"))
        await pipeline.pauseTake()
        await pipeline.reset()
        #expect(drops.count == 1 && drops.first?["paused"] as? Bool == true && drops.first?["sentences"] as? Int == 1)
        pipeline.beginTake()
        await pipeline.receive(line(1, "a take that ends"))
        await pipeline.finishTake()
        await pipeline.reset()
        #expect(drops.count == 1, "a run that ended is not dropped")
    }
}
