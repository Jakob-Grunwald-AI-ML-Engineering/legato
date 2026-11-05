import Foundation
import Synchronization
import Testing
import LegatoAgent
import LegatoClaude
import LegatoComposerDoc
import LegatoCore
@testable import LegatoAppServices

/// Cleans a take by capitalising and adding a full stop; scripted failures per call.
private final class TakeCleaner: SentenceCleaning {
    enum Behavior: Sendable { case ok, fail, garbage, hang, noKey }
    let takes = Mutex<[DictationTakeInput]>([])
    let lineCalls = Mutex(0)
    let script: Mutex<[Behavior]>
    init(_ script: [Behavior] = [.ok]) { self.script = Mutex(script) }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        lineCalls.withLock { $0 += 1 }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text.capitalized + ".")
    }
    func cleanTake(_ input: DictationTakeInput) async throws -> String {
        takes.withLock { $0.append(input) }
        switch script.withLock({ $0.count > 1 ? $0.removeFirst() : $0[0] }) {
        case .ok: return input.text.prefix(1).uppercased() + input.text.dropFirst() + "."
        case .fail: throw SentenceCleanupError.providerError
        case .garbage: return "I am sorry, but I cannot help with that request because it is not something I can do for you today."
        case .hang: try await Task.sleep(for: .seconds(30)); return ""
        case .noKey: throw MessagesStreamError.missingKey
        }
    }
}

/// Streams a take as the test feeds it pieces; each call to `cleanTakeStream` is one attempt.
private final class StreamingCleaner: SentenceCleaning {
    let attempts = Mutex<[AsyncThrowingStream<String, any Error>.Continuation]>([])
    var calls: Int { attempts.withLock { $0.count } }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence { throw SentenceCleanupError.invalidInput }
    func cleanTake(_ input: DictationTakeInput) async throws -> String { "" }
    func cleanTakeStream(_ input: DictationTakeInput) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in attempts.withLock { $0.append(continuation) } }
    }
    func yield(_ text: String, attempt: Int = 0) { attempts.withLock { $0[attempt].yield(text) } }
    func finish(attempt: Int = 0, failing: Bool = false) {
        attempts.withLock { failing ? $0[attempt].finish(throwing: SentenceCleanupError.providerError) : $0[attempt].finish() }
    }
}

private func routeLine(_ sequence: Int, _ text: String) -> DictationRouteLine {
    .init(sequence: sequence, text: text, words: text.split(separator: " ").map { Word(text: String($0)) }, reason: "endpoint")
}
@MainActor private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for \(what)")
}
private let thirteenWords = "one two three four five six seven eight nine ten eleven twelve thirteen"

private actor TakeHistory: HistoryStore {
    private var entries: [DictationEntry] = []
    func append(_ entry: DictationEntry) { entries.append(entry) }
    func upsert(_ entry: DictationEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
    }
    func recent(limit: Int) -> [DictationEntry] { Array(entries.reversed().prefix(limit)) }
    func delete(id: UUID) { entries.removeAll { $0.id == id } }
}

@MainActor private func make(_ cleaner: TakeCleaner, mode: DictationSendSetting.Mode = .onStop, pause: Double = 5,
                             clock: any Clock<Duration> = ContinuousClock(), timeout: (@Sendable (Int) -> Duration)? = nil) -> DictationPipeline {
    DictationPipeline(cleaner: cleaner, vocabulary: { ["Legato"] }, sendMode: { mode }, pauseSeconds: { pause }, clock: clock, takeTimeout: timeout)
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationTakeTests {
    @Test func onStopHoldsEveryLineAndWritesOneCleanedChunk() async {
        let cleaner = TakeCleaner()
        let pipeline = make(cleaner)
        var before = "Hi Anna, "
        pipeline.contextBefore = { before }
        await pipeline.receive(routeLine(0, "hello there"))
        before = "changed later"
        await pipeline.receive(routeLine(1, "second one"))
        await pipeline.receive(routeLine(2, "third"))
        #expect(pipeline.outbox.isEmpty && cleaner.takes.withLock { $0 }.isEmpty && cleaner.lineCalls.withLock { $0 } == 0)
        #expect(pipeline.takeLines == ["hello there", "second one", "third"] && pipeline.takePhase == .buffering)
        #expect(pipeline.takeDisplay == "hello there second one third")

        await pipeline.finishTake()
        #expect(pipeline.outbox.count == 1)
        #expect(pipeline.outbox[0].text == "Hello there second one third." && pipeline.outbox[0].cleaned)
        #expect(pipeline.outbox[0].raw == "hello there second one third" && pipeline.outbox[0].sequence == 0)
        let input = cleaner.takes.withLock { $0 }.first
        #expect(input?.text == "hello there second one third" && input?.textBeforeCursor == "Hi Anna, ", "Context is the field at take start")
        #expect(input?.vocabulary == ["Legato"] && input?.recentTakes == [])
        #expect(pipeline.takeLines.isEmpty && pipeline.takePhase == .buffering)
        await pipeline.finishTake()
        #expect(pipeline.outbox.count == 1, "Nothing buffered, nothing sent")
    }

    @Test func lineByLineKeepsThePerLinePath() async throws {
        let cleaner = TakeCleaner()
        let pipeline = make(cleaner, mode: .lineByLine)
        await pipeline.receive(routeLine(0, "hello there"))
        await pipeline.receive(routeLine(1, "second one"))
        for _ in 0..<500 where pipeline.outbox.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(pipeline.outbox.map(\.text) == ["Hello There.", "Second One."])
        #expect(cleaner.takes.withLock { $0 }.isEmpty && pipeline.takeLines.isEmpty && pipeline.countdownDeadline == nil)
    }

    @Test func afterAPauseTheQuietTimerRestartsOnActivitySendsAtTheDeadlineAndListeningContinues() async {
        let clock = VirtualClock()
        let cleaner = TakeCleaner()
        let pipeline = make(cleaner, mode: .afterPause, pause: 5, clock: clock)
        await pipeline.receive(routeLine(0, "first part"))
        #expect(pipeline.countdownStart != nil && pipeline.countdownDeadline != nil)
        let firstDeadline = pipeline.countdownDeadline
        await until("timer armed") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(4))
        #expect(pipeline.outbox.isEmpty)
        pipeline.speechActivity() // a live tail: restart from here
        await until("timer re-armed") { clock.sleeperCount == 1 && clock.armCount == 2 }
        #expect(pipeline.countdownDeadline != nil && pipeline.countdownDeadline! >= firstDeadline!)
        clock.advance(by: .seconds(4))
        #expect(pipeline.outbox.isEmpty, "4 s after the restart is still inside the pause")

        clock.advance(by: .seconds(1))
        await until("the pause send") { pipeline.outbox.count == 1 && pipeline.outbox[0].final }
        #expect(pipeline.outbox[0].text == "First part." && pipeline.countdownDeadline == nil)

        // Listening continues: the next words are a new chunk with the sent one as context.
        await pipeline.receive(routeLine(1, "and more"))
        #expect(pipeline.takeLines == ["and more"] && pipeline.countdownDeadline != nil)
        await until("timer armed again") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(5))
        await until("the second send") { pipeline.outbox.count == 2 && pipeline.outbox[1].final }
        #expect(pipeline.outbox.map(\.sequence) == [0, 1])
        #expect(cleaner.takes.withLock { $0 }.last?.recentTakes.map(\.cleaned) == ["First part."], "Earlier takes ride along as raw to cleaned pairs")
    }

    @Test func recentTakesSurviveASessionResetAndRawInsertsAreContextOnly() async {
        let cleaner = TakeCleaner([.ok, .noKey, .ok])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, thirteenWords))
        await pipeline.sendTake()
        await pipeline.reset()
        await pipeline.receive(routeLine(0, "no key here"))
        await pipeline.sendTake()
        await pipeline.reset()
        await pipeline.receive(routeLine(0, "third take"))
        await pipeline.sendTake()
        let third = cleaner.takes.withLock { $0 }.last
        #expect(third?.recentTakes.map(\.raw) == [thirteenWords], "Only the cleaned take is a raw to cleaned pair, and it outlived two resets")
        #expect(pipeline.recentTakes.recent().count == 3 && pipeline.backgroundText.contains("no key here"))
    }

    @Test func stopSendsWhatIsBufferedAndCancelsTheCountdown() async {
        let clock = VirtualClock()
        let pipeline = make(TakeCleaner(), mode: .afterPause, clock: clock)
        await pipeline.receive(routeLine(0, "stop now"))
        await until("timer armed") { clock.sleeperCount == 1 }
        await pipeline.finishTake()
        #expect(pipeline.outbox.map(\.text) == ["Stop now."] && pipeline.countdownDeadline == nil && clock.sleeperCount == 0)
    }

    @Test func aSuppressedTimerStaysQuietUntilReleased() async {
        let clock = VirtualClock()
        let pipeline = make(TakeCleaner(), mode: .afterPause, clock: clock)
        pipeline.setAutoSendSuppressed(true)
        await pipeline.receive(routeLine(0, "held key"))
        #expect(pipeline.countdownDeadline == nil && clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        #expect(pipeline.outbox.isEmpty)
        pipeline.setAutoSendSuppressed(false)
        #expect(pipeline.countdownDeadline != nil)
        await until("timer armed") { clock.sleeperCount == 1 }
    }

    @Test func onStopNeverRunsATimer() async {
        let clock = VirtualClock()
        let pipeline = make(TakeCleaner(), mode: .onStop, clock: clock)
        await pipeline.receive(routeLine(0, "no timer"))
        pipeline.speechActivity()
        #expect(pipeline.countdownDeadline == nil && clock.sleeperCount == 0)
    }

    @Test func aFailedCleanupRetriesOnceThenHoldsTheRawTextAndInsertsNothing() async {
        let cleaner = TakeCleaner([.fail])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, "keep this safe"))
        await pipeline.finishTake()
        #expect(cleaner.takes.withLock { $0 }.count == 2, "One automatic retry")
        #expect(pipeline.takePhase == .failed && pipeline.failedText == "keep this safe" && pipeline.outbox.isEmpty)
        #expect(pipeline.fallbacks == ["take-failed"])
        await pipeline.finishTake()
        #expect(pipeline.takePhase == .failed && pipeline.outbox.isEmpty, "Stopping again does not insert")
    }

    @Test func withoutAClaudeKeyTheRawTakeGoesInAtOnce() async {
        let cleaner = TakeCleaner([.noKey])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, "as heard"))
        await pipeline.finishTake()
        #expect(cleaner.takes.withLock { $0 }.count == 1)
        #expect(pipeline.takePhase == .buffering && pipeline.failedText == nil)
        #expect(pipeline.outbox.map(\.text) == ["as heard"] && pipeline.outbox.first?.cleaned == false)
    }

    @Test func aRejectedResultIsTakenBackAndTheRawTakeGoesIn() async {
        let cleaner = TakeCleaner([.garbage, .ok])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, thirteenWords))
        await pipeline.finishTake()
        #expect(cleaner.takes.withLock { $0 }.count == 1 && pipeline.takePhase == .buffering, "The guard runs at the end and never retries")
        #expect(pipeline.outbox.count == 2 && pipeline.outbox[0].retracted && pipeline.outbox[0].final, "The streamed text is erased")
        #expect(pipeline.outbox[1].text == thirteenWords && !pipeline.outbox[1].cleaned && pipeline.outbox[1].final, "The speaker's words replace it")
        #expect(pipeline.fallbacks == ["take-rejected"])
        #expect(pipeline.recentTakes.recent().last?.cleaned == thirteenWords, "The rejected text never becomes context")
    }

    @Test func historyKeepsTheRawTakeWhateverCleanupDoes() async throws {
        let history = TakeHistory()
        for script in [TakeCleaner.Behavior.garbage, .hang] {
            let pipeline = DictationPipeline(history: history, cleaner: TakeCleaner([script]), sendMode: { .onStop }, takeTimeout: { _ in .milliseconds(20) })
            await pipeline.receive(routeLine(0, thirteenWords))
            await pipeline.finishTake()
            #expect(try await history.recent(limit: 1).first?.text == thirteenWords)
        }
    }

    @Test func historyMarksATakeThatStayedRaw() async throws {
        let history = TakeHistory()
        let failing = DictationPipeline(history: history, cleaner: TakeCleaner([.fail, .fail, .ok]), sendMode: { .onStop }, takeTimeout: { _ in .milliseconds(20) })
        await failing.receive(routeLine(0, thirteenWords))
        await failing.sendTake()
        #expect(try await history.recent(limit: 1).first?.cleanupFallback == true)
        await failing.retry()
        let entries = try await history.recent(limit: 10)
        #expect(entries.count == 1 && entries.first?.cleanupFallback == nil, "A retry that cleans the take clears the mark")
    }

    @Test func aCleanedTakeUpdatesItsHistoryEntry() async throws {
        let history = TakeHistory()
        let pipeline = DictationPipeline(history: history, cleaner: TakeCleaner([.ok]), sendMode: { .onStop })
        await pipeline.receive(routeLine(0, thirteenWords))
        await pipeline.finishTake()
        let entries = try await history.recent(limit: 10)
        #expect(entries.count == 1 && entries[0].rawText == thirteenWords && entries[0].text != thirteenWords)
    }

    @Test func aSlowCleanupTimesOutPerAttemptAndEndsFailed() async {
        let cleaner = TakeCleaner([.hang])
        let pipeline = make(cleaner, timeout: { _ in .milliseconds(20) })
        await pipeline.receive(routeLine(0, "too slow"))
        await pipeline.finishTake()
        #expect(pipeline.takePhase == .failed && cleaner.takes.withLock { $0 }.count == 2)
        #expect(pipeline.fallbacks == ["take-timeout"])
    }

    @Test func retryDeliversTheCleanedTextExactlyOnce() async {
        let cleaner = TakeCleaner([.fail, .fail, .ok])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, "try again"))
        await pipeline.finishTake()
        #expect(pipeline.takePhase == .failed)
        await pipeline.retry()
        #expect(pipeline.outbox.map(\.text) == ["Try again."] && pipeline.takePhase == .buffering && pipeline.failedText == nil)
        await pipeline.retry(); await pipeline.insertRaw()
        #expect(pipeline.outbox.count == 1, "Neither action does anything once the take went out")
    }

    @Test func aRetryThatFailsAgainStaysFailed() async {
        let pipeline = make(TakeCleaner([.fail]))
        await pipeline.receive(routeLine(0, "still broken"))
        await pipeline.finishTake()
        await pipeline.retry()
        #expect(pipeline.takePhase == .failed && pipeline.outbox.isEmpty && pipeline.failedText == "still broken")
    }

    @Test func insertRawDeliversTheRawTextExactlyOnce() async {
        let cleaner = TakeCleaner([.fail])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, "as is please"))
        await pipeline.finishTake()
        await pipeline.insertRaw()
        #expect(pipeline.outbox.count == 1 && pipeline.outbox[0].text == "as is please" && !pipeline.outbox[0].cleaned)
        #expect(pipeline.takePhase == .buffering && pipeline.failedText == nil)
        await pipeline.insertRaw(); await pipeline.retry()
        #expect(pipeline.outbox.count == 1)
    }

    @Test func newSpeechAfterAFailureJoinsTheHeldTextIntoOneTake() async {
        let cleaner = TakeCleaner([.fail, .fail, .ok])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, "first held"))
        await pipeline.finishTake()
        await pipeline.receive(routeLine(1, "and then new"))
        #expect(pipeline.takePhase == .buffering && pipeline.takeLines == ["first held", "and then new"])
        await pipeline.finishTake()
        #expect(pipeline.outbox.map(\.raw) == ["first held and then new"])
    }

    @Test func resetDropsTheUnsentTakeAndAFailedOneUnlessKept() async {
        let pipeline = make(TakeCleaner([.fail]))
        await pipeline.receive(routeLine(0, "never typed"))
        await pipeline.reset()
        #expect(pipeline.takeLines.isEmpty && pipeline.outbox.isEmpty)
        await pipeline.finishTake()
        #expect(pipeline.outbox.isEmpty)

        await pipeline.receive(routeLine(0, "held text"))
        await pipeline.finishTake()
        await pipeline.reset(keepFailedTake: true)
        #expect(pipeline.takePhase == .failed && pipeline.failedText == "held text" && pipeline.nextOutboxSequenceForTesting == 0)
        await pipeline.reset()
        #expect(pipeline.takePhase == .buffering && pipeline.failedText == nil)
    }

    @Test func discardingATakeCancelsACleanupInFlight() async {
        let cleaner = TakeCleaner([.hang])
        let pipeline = make(cleaner)
        await pipeline.receive(routeLine(0, "cancel me"))
        let sending = Task { await pipeline.finishTake() }
        await until("cleanup started") { pipeline.takePhase == .cleaning && !cleaner.takes.withLock { $0 }.isEmpty }
        pipeline.discardTake()
        await sending.value
        #expect(pipeline.takePhase == .buffering && pipeline.outbox.isEmpty && pipeline.failedText == nil)
    }

    // MARK: Streaming

    @MainActor private func streaming(_ cleaner: StreamingCleaner, _ raw: String = "one two three") async -> (DictationPipeline, Task<Void, Never>) {
        let pipeline = DictationPipeline(cleaner: cleaner, vocabulary: { [] }, sendMode: { .onStop })
        await pipeline.receive(routeLine(0, raw))
        let sending = Task { @MainActor in await pipeline.finishTake() }
        await until("the attempt started") { cleaner.calls == 1 }
        return (pipeline, sending)
    }

    @Test func theCleanedTextGrowsInOneDeliveryUntilItIsFinal() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        #expect(pipeline.outbox.isEmpty && pipeline.takePhase == .cleaning)
        cleaner.yield("One ")
        await until("first delta") { pipeline.outbox.count == 1 }
        #expect(pipeline.outbox[0].text == "One " && !pipeline.outbox[0].final && pipeline.outbox[0].isTake && pipeline.outbox[0].sequence == 0)
        cleaner.yield("two three.")
        await until("second delta") { pipeline.outbox[0].text == "One two three." }
        #expect(pipeline.outbox.count == 1 && !pipeline.outbox[0].final && pipeline.takePhase == .cleaning)
        cleaner.finish()
        await sending.value
        #expect(pipeline.outbox.count == 1 && pipeline.outbox[0].final && !pipeline.outbox[0].retracted && pipeline.outbox[0].cleaned)
        #expect(pipeline.outbox[0].text == "One two three." && pipeline.takePhase == .buffering && pipeline.nextOutboxSequenceForTesting == 1)
        #expect(pipeline.recentTakes.recent().count == 1)
    }

    @Test func growthIsAnnouncedAtMostEveryFewMilliseconds() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        var announced = 0
        pipeline.onChange = { announced += 1 }
        for i in 0..<200 { cleaner.yield("w\(i) ") }
        await until("all deltas") { pipeline.outbox.first?.text.hasSuffix("w199 ") == true }
        let burst = announced
        #expect(burst < 40, "200 deltas in a burst are coalesced (\(burst) announcements)")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(announced >= 1 && announced <= burst + 1, "At most one trailing announcement carries the last growth")
        cleaner.finish()
        await sending.value
        #expect(pipeline.outbox[0].final)
    }

    @Test func aFailureBeforeAnyDeltaRetriesAutomatically() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        cleaner.finish(failing: true)
        await until("second attempt") { cleaner.calls == 2 }
        cleaner.yield("One, two, three.", attempt: 1); cleaner.finish(attempt: 1)
        await sending.value
        #expect(pipeline.outbox.map(\.text) == ["One, two, three."] && pipeline.takePhase == .buffering)
    }

    @Test func aFailureAfterDeltasKeepsThePartialAndWaitsForTheUser() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        cleaner.yield("One two")
        await until("delta") { pipeline.outbox.count == 1 }
        cleaner.finish(failing: true)
        await sending.value
        #expect(cleaner.calls == 1, "No automatic retry once text is in the field")
        #expect(pipeline.takePhase == .failed && pipeline.failedText == "one two three")
        #expect(pipeline.outbox.count == 1 && pipeline.outbox[0].failed && !pipeline.outbox[0].final && !pipeline.outbox[0].retracted)
        #expect(pipeline.fallbacks == ["take-failed"])
    }

    @Test func retryRetractsThePartialThenStreamsANewDelivery() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        cleaner.yield("One two"); await until("delta") { pipeline.outbox.count == 1 }
        cleaner.finish(failing: true); await sending.value
        let retrying = Task { @MainActor in await pipeline.retry() }
        await until("second attempt") { cleaner.calls == 2 }
        #expect(pipeline.outbox[0].retracted && pipeline.outbox[0].final && pipeline.outbox[0].text == "One two")
        cleaner.yield("One two three.", attempt: 1); cleaner.finish(attempt: 1)
        await retrying.value
        #expect(pipeline.outbox.map(\.sequence) == [0, 1] && pipeline.outbox[1].text == "One two three." && pipeline.outbox[1].final)
        #expect(!pipeline.outbox[1].retracted)
    }

    @Test func insertRawRetractsThePartialThenDeliversTheRawTake() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        cleaner.yield("One two"); await until("delta") { pipeline.outbox.count == 1 }
        cleaner.finish(failing: true); await sending.value
        await pipeline.insertRaw()
        #expect(pipeline.outbox.count == 2 && pipeline.outbox[0].retracted)
        #expect(pipeline.outbox[1].text == "one two three" && !pipeline.outbox[1].cleaned && pipeline.outbox[1].final && !pipeline.outbox[1].retracted)
    }

    @Test func aPartialTheKeyboardAlreadyDroppedIsNotRetracted() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        cleaner.yield("One two"); await until("delta") { pipeline.outbox.count == 1 }
        cleaner.finish(failing: true); await sending.value
        pipeline.acknowledge(sessionID: pipeline.sessionID, upTo: 0) // the user typed over it
        await pipeline.insertRaw()
        #expect(pipeline.outbox.map(\.text) == ["one two three"])
    }

    @Test func discardingAStreamingTakeKeepsWhatWasTyped() async {
        let cleaner = StreamingCleaner()
        let (pipeline, sending) = await streaming(cleaner)
        cleaner.yield("One two"); await until("delta") { pipeline.outbox.count == 1 }
        pipeline.discardTake()
        await sending.value
        #expect(pipeline.outbox.count == 1 && pipeline.outbox[0].final && pipeline.outbox[0].text == "One two")
    }

    #if DEBUG || LEGATO_INTERNAL
    @Test func theScriptedStreamCleanerStreamsThenFailsOnceAndRetrySucceeds() async {
        let pipeline = make(TakeCleaner())
        pipeline.debugStreamCleaner = DebugStreamingCleaner(chunkMilliseconds: 1, failAfterChunks: 2)
        await pipeline.receive(routeLine(0, "hello there general"))
        await pipeline.finishTake()
        #expect(pipeline.takePhase == .failed)
        #expect(pipeline.outbox.count == 1 && pipeline.outbox[0].failed && pipeline.outbox[0].text == "Hello There ")
        await pipeline.retry()
        #expect(pipeline.outbox.count == 2 && pipeline.outbox[0].retracted)
        #expect(pipeline.outbox[1].text == "Hello There General" && pipeline.outbox[1].final)
    }
    @Test func theDebugSwitchForcesTheNextTakeToFail() async {
        let cleaner = TakeCleaner()
        let pipeline = make(cleaner)
        pipeline.debugFailTakes = 1
        await pipeline.receive(routeLine(0, "forced"))
        await pipeline.finishTake()
        #expect(pipeline.takePhase == .failed && cleaner.takes.withLock { $0 }.isEmpty)
        await pipeline.retry()
        #expect(pipeline.outbox.map(\.text) == ["Forced."])
    }
    #endif
}
