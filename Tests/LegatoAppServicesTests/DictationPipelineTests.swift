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
/// The first two calls take 200 ms, later ones return at once; everything is upper-cased.
private final class SlowFirstCleaner: SentenceCleaning {
    let inputs = Mutex<[SentenceCleanupInput]>([])
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        let n = inputs.withLock { $0.append(input); return $0.count }
        if n <= 2 { try await Task.sleep(for: .milliseconds(200)) }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text.uppercased())
    }
}
private final class FnCleaner: SentenceCleaning {
    let inputs = Mutex<[SentenceCleanupInput]>([])
    let transform: @Sendable (SentenceCleanupInput) -> String
    init(_ transform: @escaping @Sendable (SentenceCleanupInput) -> String) { self.transform = transform }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        inputs.withLock { $0.append(input) }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: transform(input))
    }
}
/// Drops fillers the way the model does: an all-filler unit comes back empty.
private final class UnitCleaner: SentenceCleaning {
    let inputs = Mutex<[SentenceCleanupInput]>([])
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        inputs.withLock { $0.append(input) }
        let fillers: Set<String> = ["um", "uh", "so", "yeah"]
        let words = input.text.split(separator: " ").map(String.init).filter { !fillers.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        let text = words.joined(separator: " ")
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: text.prefix(1).uppercased() + text.dropFirst())
    }
}
private func routeLine(_ sequence: Int, _ text: String, reason: String = "endpoint") -> DictationRouteLine {
    .init(sequence: sequence, text: text, words: text.split(separator: " ").map { Word(text: String($0)) }, reason: reason)
}
/// Polls until `condition` holds, for at most 10 s of real time (a slow runner fails fast instead of hanging the suite).
@MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    if !condition() { Issue.record("Timed out waiting for condition") }
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

    @Test func theTargetIsRawFinalsThenTheHeadAndCleanedSentencesLandOnceTheTakeEnds() async throws {
        // Call 2 is the whole take's cleanup at the stop: it times out too, so the units' results stand.
        let cleaner = StubCleaner(slow: [0, 2])
        let pipeline = live(cleaner)
        var published: [LiveDictationSnapshot?] = []
        pipeline.onLiveChange = { published.append($0) }
        pipeline.tailChanged("hello wor")
        await pipeline.receive(routeLine(0, "hello world this is sentence one."))
        pipeline.tailChanged("and then")
        let run = try #require(pipeline.liveRun)
        #expect(run.snapshot.segments == [.init(id: 0, text: "hello world this is sentence one.", final: true), .init(id: 1, text: "and then", final: false)])
        // Sentence 1 is cleaned (sentence 0 is slow) but held back while the mic is open.
        await pipeline.receive(routeLine(1, "and this is the second one."))
        try await until { pipeline.pending < 2 }
        #expect(pipeline.liveRun?.snapshot.segments.contains { $0.cleaned } == false)
        #expect(published.allSatisfy { $0?.segments.contains { $0.cleaned } != true })
        // The stop waits for cleanup (sentence 0 times out: raw), then publishes one target with the cleaned sentences.
        let before = published.count
        await pipeline.finishTake()
        #expect(published.count == before + 1)
        let last = try #require(published.last ?? nil)
        #expect(last.complete && last.segments == [.init(id: 0, text: "hello world this is sentence one.", final: true),
                                                   .init(id: 1, text: "And This Is The Second One..", cleaned: true, final: true)])
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
        await pipeline.receive(routeLine(0, "slow words that end a sentence."))
        try await until { pipeline.fallbacks == ["timeout"] }
        #expect(pipeline.liveRun?.snapshot.segments == [.init(id: 0, text: "slow words that end a sentence.", final: true)])
        await pipeline.reset()
        #expect(pipeline.liveRun == nil)
        #expect(last == .some(nil), "The link's run is removed")
    }

    @Test func switchingFromLiveToLineByLineKeepsDeliveringLines() async throws {
        nonisolated(unsafe) var mode = DictationSendSetting.Mode.live
        let pipeline = DictationPipeline(cleaner: StubCleaner(), sendMode: { mode }, supportsLive: true, liveTimeout: .milliseconds(200))
        await pipeline.receive(routeLine(0, "first"))
        await pipeline.receive(routeLine(1, "second"))
        try await until { pipeline.pending == 0 }
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
        // The take's end closes the unit; a late segment is a unit of its own.
        await pipeline.finishTake()
        await pipeline.receive(routeLine(1, "second one"))
        // The late segment also reruns the short take's whole pass (a third call, sequence 2): wait for the unit's call
        // by sequence, never for an exact count, which the third call can overtake.
        try await until { cleaner.inputs.withLock { inputs in inputs.contains { $0.sequence == 1 } } }
        let inputs = cleaner.inputs.withLock { $0 }
        #expect(inputs.first { $0.sequence == 0 }?.dictation?.textBeforeCursor == "Hi Anna,")
        #expect(inputs.first { $0.sequence == 1 }?.dictation?.textBeforeCursor == "Hi Anna, hello world.", "A closed sentence is shown as finished")
    }

    @Test func aSentenceTheSegmenterCutShortIsCleanedOnceWhole() async throws {
        let cleaner = StubCleaner()
        let pipeline = live(cleaner)
        await pipeline.receive(routeLine(0, "we need the report", reason: "words"))
        await pipeline.receive(routeLine(1, "by next tuesday or else", reason: "duration"))
        #expect(cleaner.inputs.withLock { $0.count } == 0, "Nothing is cleaned until the sentence ends")
        await pipeline.receive(routeLine(2, "the client leaves", reason: "punctuation"))
        await pipeline.finishTake()
        #expect(pipeline.liveRun?.snapshot.segments.first?.cleaned == true)
        let inputs = cleaner.inputs.withLock { $0 }
        #expect(inputs.count == 1 && inputs[0].text == "we need the report by next tuesday or else the client leaves")
        #expect(pipeline.liveRun?.snapshot.segments.count == 1)
    }

    @Test func aSegmentAndACleanupThatArriveAfterTheTakesEndStayInTheSameRun() async throws {
        let cleaner = StubCleaner(slow: [1])
        let pipeline = live(cleaner, timeout: .seconds(5))
        pipeline.tailChanged("first sentence")
        await pipeline.receive(routeLine(0, "first sentence."))
        pipeline.tailChanged("last words")
        let runID = pipeline.liveRun?.runID
        // The stop is seen before the last segment's event reaches the sink; the head still shows its words.
        await pipeline.finishTake()
        #expect(pipeline.liveRun?.complete == true)
        await pipeline.receive(routeLine(1, "last words."))
        #expect(pipeline.liveRun?.runID == runID, "No second run for the straggler")
        #expect(pipeline.liveRun?.snapshot.segments.map(\.final) == [true, true])
        #expect(pipeline.liveRun?.snapshot.segments.last?.text == "last words.")
    }

    @Test func pauseFragmentsAreCleanedAsOneUnitAndAnAllFillerUnitIsDropped() async throws {
        let cleaner = UnitCleaner()
        let pipeline = DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: .milliseconds(500))
        var diagnostics: [[String: Any]] = []
        pipeline.diagnostics = { event, fields in if event == "live2.cleanup" { diagnostics.append(fields) } }
        await pipeline.receive(routeLine(0, "Um."))
        await pipeline.receive(routeLine(1, "so, uh, the plan"))
        #expect(cleaner.inputs.withLock { $0.count } == 0, "A pause fragment is not cleaned alone")
        await pipeline.receive(routeLine(2, "is ready for the review."))
        await pipeline.receive(routeLine(3, "Yeah."))
        await pipeline.finishTake()
        let texts = cleaner.inputs.withLock { $0.map(\.text) }
        #expect(texts == ["Um. so, uh, the plan is ready for the review.", "Yeah.", "Um. so, uh, the plan is ready for the review. Yeah."],
                "The units, then the short take whole")
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.complete && snapshot.segments.map(\.text) == ["The plan is ready for the review.", "", "", ""])
        let allCleaned = snapshot.segments.allSatisfy { $0.cleaned }
        #expect(allCleaned)
        // `changed` says whether the cleaned unit differs from its raw words, held or not.
        let changedWhileHeld = diagnostics.allSatisfy { $0["changed"] as? Bool == true && $0["held"] as? Bool == true }
        #expect(diagnostics.count == 2 && changedWhileHeld)
        #expect(diagnostics.last?["dropped"] as? Bool == true && diagnostics.first?["segments"] as? Int == 3)
    }

    @Test func aShortTakeIsCleanedWholeAtTheStopSoACorrectionInALaterUnitReplacesWhatItCorrects() async throws {
        let cleaner = FnCleaner { input in
            input.text.contains("Wednesday") && input.text.contains("Tuesday") ? "We moved the review to Wednesday." : input.text
        }
        let pipeline = DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: .milliseconds(500))
        var ends: [[String: Any]] = []
        pipeline.diagnostics = { event, fields in if event == "live2.run.end" { ends.append(fields) } }
        await pipeline.receive(routeLine(0, "we moved the review to Tuesday."))
        await pipeline.receive(routeLine(1, "Uh,"))
        await pipeline.receive(routeLine(2, "no sorry Wednesday."))
        await pipeline.finishTake()
        let snapshot = try #require(pipeline.liveRun?.snapshot)
        #expect(snapshot.segments.map(\.text) == ["We moved the review to Wednesday.", "", ""])
        #expect(ends.first?["whole"] as? String == "landed" && ends.first?["stopMs"] is Int)
    }

    @Test func aSegmentThatArrivesWhileTheStopWaitsIsCleanedToo() async throws {
        let cleaner = SlowFirstCleaner()
        let pipeline = DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: .milliseconds(500))
        await pipeline.receive(routeLine(0, "we moved the review to next week."))
        await pipeline.receive(routeLine(1, "and the budget"))
        let stop = Task { await pipeline.finishTake() }
        try await until { cleaner.inputs.withLock { $0.count } >= 2 }
        await pipeline.receive(routeLine(2, "Yeah."))
        await stop.value
        #expect(pipeline.liveRun?.snapshot.segments.last?.cleaned == true, "The late segment's unit is cleaned before the take ends")
    }

    @Test func theStopWaitsForTheFinalOfWordsStillSpokenAndCleansTheTakeWholeWithThem() async throws {
        let cleaner = FnCleaner { $0.text.replacingOccurrences(of: "we could we could", with: "we could").capitalized }
        let pipeline = DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: .milliseconds(500))
        await pipeline.receive(routeLine(0, "the draft is done and reviewed now."))
        pipeline.tailChanged("we could we could")
        let stop = Task { await pipeline.finishTake() }
        try await Task.sleep(for: .milliseconds(100))
        await pipeline.receive(routeLine(1, "we could we could send it today"))
        await stop.value
        let texts = cleaner.inputs.withLock { $0.map(\.text) }
        #expect(texts.contains("the draft is done and reviewed now. we could we could send it today"), "The whole pass has the late final")
        #expect(pipeline.liveRun?.snapshot.segments.map(\.text) == ["The Draft Is Done And Reviewed Now. We Could Send It Today", ""])
    }

    @Test func aStragglerAfterTheEndOfAShortTakeRunsTheWholePassAgain() async throws {
        let cleaner = FnCleaner { $0.text.replacingOccurrences(of: "we could we could", with: "we could").uppercased() }
        let pipeline = DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: .milliseconds(500))
        await pipeline.receive(routeLine(0, "the draft is done and reviewed now."))
        await pipeline.finishTake()
        #expect(pipeline.liveRun?.complete == true && pipeline.liveRun?.unitCount == 1)
        await pipeline.receive(routeLine(1, "we could we could send it today"))
        try await until { pipeline.liveRun?.snapshot.segments.first?.text == "THE DRAFT IS DONE AND REVIEWED NOW. WE COULD SEND IT TODAY" }
        #expect(pipeline.liveRun?.snapshot.segments.map(\.text) == ["THE DRAFT IS DONE AND REVIEWED NOW. WE COULD SEND IT TODAY", ""])
    }

    @Test func anInstructionEndsAndSealsTheRun() async throws {
        let pipeline = live()
        var published: [LiveDictationSnapshot?] = []
        pipeline.onLiveChange = { published.append($0) }
        await pipeline.receive(routeLine(0, "first part of it."))
        await pipeline.receive(routeLine(1, "second part here."))
        await pipeline.finishLiveRun()
        let sealed = try #require(pipeline.liveRun?.snapshot)
        #expect(sealed.complete && sealed.segments.allSatisfy(\.cleaned), "The instruction reads the cleaned take")
        // A segment right after (within the straggler grace) never joins the sealed run or its whole-take pass.
        await pipeline.receive(routeLine(2, "after the instruction."))
        #expect(pipeline.liveRun?.runID != sealed.runID)
        #expect(!published.contains { $0?.runID == sealed.runID && $0 != sealed && $0?.version ?? 0 > sealed.version })
    }

    @Test func aLongTakeKeepsItsUnits() async throws {
        let cleaner = FnCleaner { $0.text.uppercased() }
        let pipeline = DictationPipeline(cleaner: cleaner, sendMode: { .live }, supportsLive: true, liveTimeout: .milliseconds(500))
        let sentence = Array(repeating: "word", count: 45).joined(separator: " ") + "."
        await pipeline.receive(routeLine(0, sentence))
        await pipeline.receive(routeLine(1, sentence))
        await pipeline.finishTake()
        #expect(cleaner.inputs.withLock { $0.count } == 2, "No whole call over \(DictationPipeline.wholeTakeWords) words")
        #expect(pipeline.liveRun?.snapshot.segments.map(\.text) == [sentence.uppercased(), sentence.uppercased()])
    }

    @Test func lineByLineStopWaitsForTheLastLineToBeCleaned() async {
        let pipeline = DictationPipeline(cleaner: StubCleaner(), sendMode: { .lineByLine })
        await pipeline.receive(routeLine(0, "one"))
        await pipeline.finishTake()
        #expect(pipeline.outbox.map(\.text) == ["One."])
    }

    @Test func withoutLiveSupportTheSettingActsAsOnStop() async {
        let pipeline = live(supportsLive: false)
        #expect(pipeline.mode == .onStop)
        await pipeline.receive(routeLine(0, "held"))
        #expect(pipeline.liveRun == nil && pipeline.takeLines == ["held"])
    }
}
