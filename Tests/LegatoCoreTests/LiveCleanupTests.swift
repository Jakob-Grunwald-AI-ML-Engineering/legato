import Foundation
import Synchronization
import Testing
@testable import LegatoCore

/// A live-cleaning post-processor: cleans each pass with `clean` (nil throws), can hold a pass (by its input)
/// until released, and records every call, how many ran at once and which were cancelled.
final class LivePassProcessor: TranscriptPostProcessor {
    struct Call: Equatable {
        var text: String
        var context: String
        var atStop: Bool
    }

    private struct State {
        var calls: [Call] = []
        var wholeTexts: [String] = []
        var held: Set<String> = []
        var active = 0
        var maxActive = 0
        var cancelled: [String] = []
        var runStarts = 0
    }

    let id = "live"
    let cleansSegmentsLive: Bool
    let liveStopTimeLimit: Duration?
    private let clean: @Sendable (String) -> LivePassResult?
    private let state = Mutex(State())

    init(
        live: Bool = true, hold: Set<String> = [], stopLimit: Duration? = nil,
        clean: @escaping @Sendable (String) -> LivePassResult?
    ) {
        cleansSegmentsLive = live
        liveStopTimeLimit = stopLimit
        self.clean = clean
        state.withLock { $0.held = hold }
    }

    /// Answers from a table; a missing entry throws.
    convenience init(live: Bool = true, answers: [String: String], hold: Set<String> = [], stopLimit: Duration? = nil) {
        self.init(live: live, hold: hold, stopLimit: stopLimit) { answers[$0].map { LivePassResult(text: $0) } }
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var wholeTexts: [String] { state.withLock { $0.wholeTexts } }
    var maxActive: Int { state.withLock { $0.maxActive } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    var runStarts: Int { state.withLock { $0.runStarts } }
    func liveRunStarts() { state.withLock { $0.runStarts += 1 } }
    func release(_ text: String) { _ = state.withLock { $0.held.remove(text) } }

    func process(_ text: String, locale: Locale) async throws -> String {
        state.withLock { $0.wholeTexts.append(text) }
        guard let out = clean(text) else { throw TestError(tag: "no answer") }
        return out.text
    }

    func cleanLivePass(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> LivePassResult {
        state.withLock {
            $0.calls.append(Call(text: text, context: context, atStop: atStop))
            $0.active += 1
            $0.maxActive = max($0.maxActive, $0.active)
        }
        defer { state.withLock { $0.active -= 1 } }
        while state.withLock({ $0.held.contains(text) }) {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                state.withLock { $0.cancelled.append(text) }
                throw error
            }
        }
        guard let out = clean(text) else { throw TestError(tag: "no answer") }
        return out
    }
}

/// Collects a session's edits as they are published, and its live trace.
@MainActor
final class LiveEditRecorder {
    private(set) var edits: [TranscriptEdit] = []
    private(set) var trace: [LiveTraceEvent] = []
    private var task: Task<Void, Never>?

    init(_ session: DictationSession) {
        let stream = session.edits
        task = Task { [weak self] in
            for await edit in stream { self?.edits.append(edit) }
        }
        session.onLiveTrace = { [weak self] in self?.trace.append($0) }
    }

    var revisions: [TranscriptRevision] {
        edits.compactMap { if case .revise(let r) = $0 { r } else { nil } }
    }

    var commits: [String] {
        edits.compactMap { if case .commit(let d) = $0 { d } else { nil } }
    }

    var passes: [LivePassReport] {
        trace.compactMap { if case .pass(let p) = $0 { p } else { nil } }
    }

    var sent: [LiveSentReport] {
        trace.compactMap { if case .sent(let s) = $0 { s } else { nil } }
    }
}

@MainActor
private func liveSession(
    _ processor: LivePassProcessor, script: [TranscriptEvent] = [], deadline: Deadline = Deadline()
) -> (DictationSession, FakeEngine) {
    let log = EventLog()
    let engine = FakeEngine(log: log)
    engine.set(script: script)
    let session = DictationSession(
        engine: engine, source: FakeSource(log: log), sessionControl: FakeSessionControl(log: log),
        history: MemoryHistory(), postProcessor: processor, sleep: { try await deadline.wait(for: $0) },
        now: { Date(timeIntervalSince1970: 100) })
    return (session, engine)
}

/// The session's sleeper, held until the test fires it; records how long each wait was asked for.
final class Deadline: Sendable {
    private struct State {
        var fired = false
        var asked: [Duration] = []
    }

    private let state = Mutex(State())

    var asked: [Duration] { state.withLock { $0.asked } }
    func fire() { state.withLock { $0.fired = true } }

    func wait(for duration: Duration) async throws {
        state.withLock { $0.asked.append(duration) }
        while !state.withLock({ $0.fired }) { try await Task.sleep(for: .milliseconds(2)) }
    }
}

private func final(_ text: String) -> TranscriptEvent { TranscriptEvent(text: text, isFinal: true) }

@MainActor
@Suite struct LiveCleanupSessionTests {
    // MARK: rolling passes

    @Test func eachCommitStartsAPassOverTheWholeRawTextSoFar() async throws {
        let processor = LivePassProcessor(answers: [
            "hello world": "Hello world.",
            "hello world how are you": "Hello world, how are you?",
        ])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(recorder.revisions == [
            TranscriptRevision(n: 1, start: 0, raw: "hello world ", text: "Hello world. "),
            TranscriptRevision(n: 2, start: 0, raw: "hello world how are you ", text: "Hello world, how are you? "),
        ])
        // Every pass gets the raw text, never the cleaned text of an earlier pass, and no context.
        #expect(processor.calls == [
            .init(text: "hello world", context: "", atStop: false),
            .init(text: "hello world how are you", context: "", atStop: false),
        ])

        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world, how are you?")
        #expect(entry.rawText == "hello world how are you")
        #expect(processor.calls.count == 2, "the last pass covered all of it: no stop pass")
        #expect(processor.wholeTexts.isEmpty)
    }

    @Test func passesDoNotStackAndTheNextOneTakesTheNewestRawText() async throws {
        let processor = LivePassProcessor(
            answers: ["one": "One.", "one two three": "One, two, three."], hold: ["one"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("one "), run: 0)
        #expect(await eventually { processor.calls.count == 1 })
        engine.emit(final("two "), run: 0)
        engine.emit(final("three "), run: 0)
        #expect(await eventually { recorder.commits.count == 3 })
        try await Task.sleep(for: .milliseconds(40))
        #expect(processor.calls.count == 1, "one pass in flight at most")

        processor.release("one")
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(processor.maxActive == 1)
        #expect(processor.calls.map(\.text) == ["one", "one two three"], "the intermediate text is dropped")
        #expect(recorder.revisions.map(\.raw) == ["one ", "one two three "])
        _ = try await s.stop()
    }

    @Test func aSlowPassNeverHoldsBackRecognition() async throws {
        let processor = LivePassProcessor(answers: ["one": "One."], hold: ["one"])
        let (s, _) = liveSession(
            processor, script: [final("one "), final("two "), TranscriptEvent(text: "thr", isFinal: false)])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { recorder.commits == ["one ", "two "] && recorder.edits.last == .replaceVolatile("thr") })
        #expect(recorder.revisions.isEmpty, "the first pass is still running")
        processor.release("one")
        _ = try await s.stop()
    }

    @Test func aFailedPassPublishesNothingAndTheNextPassStillRuns() async throws {
        let processor = LivePassProcessor(answers: ["hello world how are you": "Hello world. How are you?"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.passes.count == 1 })
        #expect(recorder.passes.first?.outcome == .error)
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })
        #expect(recorder.revisions == [
            TranscriptRevision(n: 1, start: 0, raw: "hello world how are you ", text: "Hello world. How are you? "),
        ])
        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world. How are you?")
    }

    @Test func anUnchangedRunHasNoRawText() async throws {
        let processor = LivePassProcessor(answers: ["Hello.": "Hello."])
        let (s, _) = liveSession(processor, script: [final("Hello. ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 && recorder.passes.count == 1 })
        let entry = try #require(try await s.stop())
        #expect(recorder.revisions.isEmpty)
        #expect(recorder.passes.map(\.outcome) == [.unchanged])
        #expect(entry.text == "Hello.")
        #expect(entry.rawText == nil)
    }

    @Test func anAbortCancelsThePassInFlightAndRevisesNothing() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world."], hold: ["hello world"])
        let (s, engine) = liveSession(processor, script: [final("hello world ")])
        let recorder = LiveEditRecorder(s)
        var aborted = false
        s.onRunAborted = { _ in aborted = true }
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 })

        engine.failStream(with: TestError(tag: "stream"), run: 0)
        #expect(await eventually { aborted })
        #expect(await eventually { processor.cancelled == ["hello world"] })
        processor.release("hello world")
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.revisions.isEmpty)
        #expect(s.partialEntry()?.text == "hello world", "the salvage stays the raw text")
    }

    // MARK: stop

    @Test func theStopReplacesAStalePassWithOneFinalPassOverTheWholeRawText() async throws {
        let processor = LivePassProcessor(
            answers: ["one": "One.", "one two three": "One, two, three."], hold: ["one"])
        let (s, _) = liveSession(processor, script: [final("one "), final("two "), final("three ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 && recorder.commits.count == 3 })

        let entry = try #require(try await s.stop())
        #expect(processor.cancelled == ["one"], "the pass over old text gives way")
        #expect(processor.calls == [
            .init(text: "one", context: "", atStop: false),
            .init(text: "one two three", context: "", atStop: true),
        ])
        #expect(recorder.revisions == [
            TranscriptRevision(n: 1, start: 0, raw: "one two three ", text: "One, two, three. "),
        ])
        #expect(entry.text == "One, two, three.")
        #expect(entry.rawText == "one two three")
        #expect(recorder.passes.map(\.outcome) == [.superseded, .published])
        #expect(recorder.passes.map(\.final) == [false, true])
    }

    @Test func aPassInFlightOverAllOfTheTextIsTheFinalPass() async throws {
        let processor = LivePassProcessor(answers: ["one two": "One, two."], hold: ["one two"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("one two "), run: 0)
        #expect(await eventually { processor.calls.count == 1 })
        let stop = Task { try await s.stop() }
        #expect(await eventually { s.runState == .finishing })
        processor.release("one two")
        let entry = try #require(try await stop.value)
        #expect(processor.calls.count == 1, "no second pass over the same text")
        #expect(entry.text == "One, two.")
        #expect(recorder.passes.map(\.final) == [true])
    }

    @Test func atTheDeadlineTheNewestPublishedTextAndTheRawTailAreKept() async throws {
        let processor = LivePassProcessor(
            answers: ["one": "One.", "one two": "One, two."], hold: ["one two"], stopLimit: .seconds(3))
        let deadline = Deadline()
        let (s, engine) = liveSession(processor, deadline: deadline)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("one "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })
        engine.emit(final("two "), run: 0)
        #expect(await eventually { processor.calls.count == 2 })

        let stop = Task { try await s.stop() }
        #expect(await eventually { deadline.asked == [.seconds(3)] }, "one deadline, the setting's time limit")
        deadline.fire()
        #expect(await eventually { s.runState == .idle }, "the stop ends at the deadline")
        processor.release("one two")
        let entry = try #require(try await stop.value)

        #expect(entry.text == "One. two")
        #expect(entry.rawText == "one two")
        #expect(processor.cancelled == ["one two"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.revisions.count == 1, "nothing is published after the deadline")
        #expect(recorder.passes.last?.outcome == .timeout)
        #expect(recorder.passes.last?.final == true)
    }

    @Test func aStopThatFinishesInTimeKeepsTheFinalPass() async throws {
        let processor = LivePassProcessor(
            answers: ["one": "One.", "one two three": "One, two, three."], hold: ["one"], stopLimit: .seconds(3))
        let (s, _) = liveSession(processor, script: [final("one "), final("two "), final("three ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 && recorder.commits.count == 3 })
        let entry = try #require(try await s.stop())
        #expect(entry.text == "One, two, three.")
        #expect(processor.calls.last?.atStop == true)
    }

    // MARK: length cap

    @Test func pastTheCapTheCleanedTextIsFrozenAndOnlyTheTrailingWindowIsPassed() async throws {
        #expect(DictationSession.liveWholeTextCharacters == 2_000)
        let words = (0..<120).map { "word\($0)" }.joined(separator: " ") // 800 characters or so
        let first = "alpha " + words + " "
        let rest = ["bravo " + words + " ", "charlie " + words + " "]
        let cap = DictationSession.liveWholeTextCharacters
        #expect(first.count < cap && first.count + rest.joined().count > cap)

        let processor = LivePassProcessor(hold: [first.trimmingCharacters(in: .whitespaces)]) {
            LivePassResult(text: $0.uppercased())
        }
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final(first), run: 0)
        #expect(await eventually { processor.calls.count == 1 })
        for part in rest { engine.emit(final(part), run: 0) }
        #expect(await eventually { recorder.commits.count == 3 })
        processor.release(first.trimmingCharacters(in: .whitespaces))
        #expect(await eventually { recorder.revisions.count == 2 })

        let window = rest.joined()
        let frozen = first.uppercased()
        #expect(processor.calls.last == .init(
            text: window.trimmingCharacters(in: .whitespaces), context: frozen.trimmingCharacters(in: .whitespaces),
            atStop: false))
        #expect(recorder.revisions.last == TranscriptRevision(
            n: 2, start: 0, raw: first + window, text: frozen + window.uppercased()))
        let entry = try #require(try await s.stop())
        #expect(entry.text == (frozen + window.uppercased()).trimmingCharacters(in: .whitespaces))
    }

    // MARK: trace

    @Test func eachPassIsTracedWithLengthsAndItsOutcome() async throws {
        let processor = LivePassProcessor { text in
            switch text {
            case "one": LivePassResult(text: "One.", backend: "Qwen", device: "GPU")
            case "one two": LivePassResult(text: "one two", guardRejected: true)
            case "one two three": LivePassResult(text: "one two three", timedOut: true)
            default: nil
            }
        }
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        for (i, part) in ["one ", "two ", "three ", "four "].enumerated() {
            engine.emit(final(part), run: 0)
            #expect(await eventually { recorder.passes.count == i + 1 })
        }
        let passes = recorder.passes
        #expect(passes.map(\.outcome) == [.published, .guardRejected, .timeout, .error])
        #expect(passes.map(\.inputCharacters) == [3, 7, 13, 18])
        #expect(passes[0].outputCharacters == 4)
        #expect(passes[0].backend == "Qwen" && passes[0].device == "GPU")
        #expect(passes.map(\.n) == [1, 2, 3, 4])
        _ = try await s.stop()
    }

    // MARK: sent boundary

    @Test func afterASentBoundaryPassesCoverOnlyTheTextCommittedAfterIt() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world.", "how are you": "How are you?"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })

        s.liveTextSent(upTo: 12, shownRevision: 1)
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(recorder.revisions.last == TranscriptRevision(n: 2, start: 12, raw: "how are you ", text: "How are you? "))
        #expect(processor.calls.map(\.text) == ["hello world", "how are you"], "the sent part is not cleaned again")
        #expect(recorder.sent == [LiveSentReport(rawCharacters: 12, shownCharacters: 13, cancelledPasses: 0)])

        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world. How are you?", "the sent part as it was shown, then the rest")
        #expect(entry.rawText == "hello world how are you")
    }

    @Test func aSentBoundaryCancelsThePassInFlightForTheSentText() async throws {
        let processor = LivePassProcessor(
            answers: ["hello world": "Hello world.", "how are you": "How are you?"], hold: ["hello world"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { processor.calls.count == 1 })

        s.liveTextSent(upTo: 12, shownRevision: 0)
        #expect(await eventually { processor.cancelled == ["hello world"] })
        processor.release("hello world")
        #expect(recorder.sent == [LiveSentReport(rawCharacters: 12, shownCharacters: 12, cancelledPasses: 1)])
        let entry = try #require(try await s.stop())
        #expect(recorder.revisions.isEmpty, "nothing for the sent text, nothing left after it")
        #expect(entry.text == "hello world")
        #expect(processor.calls.count == 1, "no stop pass over the sent text")
    }

    @Test func theStopPassCoversOnlyTheTextAfterTheBoundary() async throws {
        let processor = LivePassProcessor(
            answers: ["one": "One.", "two": "Two."], hold: ["one"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("one "), run: 0)
        #expect(await eventually { processor.calls.count == 1 })
        s.liveTextSent(upTo: 4, shownRevision: 0)
        processor.release("one")
        engine.emit(final("two "), run: 0)
        #expect(await eventually { recorder.commits.count == 2 })
        let entry = try #require(try await s.stop())
        #expect(processor.calls.map(\.text).last == "two")
        #expect(recorder.revisions.last?.start == 4)
        #expect(entry.text == "one Two.")
        #expect(entry.rawText == "one two")
    }

    @Test func theTentativeTextSentWithTheMessageIsNeverCleanedAgain() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world.", "you": "You?"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })

        // The field showed "Hello world. how are" ("how are" tentative) when it was sent.
        s.liveTextSent(upTo: 12, shownRevision: 1, tentative: "how are")
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(recorder.revisions.last == TranscriptRevision(n: 2, start: 20, raw: "you ", text: "You? "))
        #expect(processor.calls.map(\.text) == ["hello world", "you"], "the sent phrase is not cleaned again")

        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world. how are You?", "the sent message as it was shown, then the rest")
    }

    @Test func aSendReportedAfterTheTentativePhraseWasCommittedStillLeavesItOut() async throws {
        let processor = LivePassProcessor(
            answers: ["hello world": "Hello world.", "hello world how are you": "Hello world. How are you?", "you": "You?"],
            hold: ["hello world how are you"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { processor.calls.count == 2 })

        // The keyboard had not seen the commit yet: the field still showed "how are" as tentative.
        s.liveTextSent(upTo: 12, shownRevision: 1, tentative: "how are")
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(recorder.revisions.last == TranscriptRevision(n: 2, start: 20, raw: "you ", text: "You? "))
        processor.release("hello world how are you")
        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world. how are You?")
    }

    @Test func aSendDuringTheStopLeavesTheTentativeTextOutOfTheStopPass() async throws {
        let processor = LivePassProcessor(
            answers: ["hello world": "Hello world.", "hello world how are you": "Hello world. How are you?", "you": "You?"],
            hold: ["hello world how are you"])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { processor.calls.count == 2 })

        let stopping = Task { try await s.stop() }
        #expect(await eventually { s.runState == .finishing })
        s.liveTextSent(upTo: 12, shownRevision: 1, tentative: "how are")
        let entry = try #require(try await stopping.value)
        processor.release("hello world how are you")
        #expect(entry.text == "Hello world. how are You?")
        #expect(recorder.revisions.last?.start == 20, "the stop pass covers only what followed the sent phrase")
        #expect(processor.calls.last?.text == "you")
    }

    @Test func aBoundaryThatDoesNotMoveForwardIsIgnored() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world."])
        let (s, engine) = liveSession(processor)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { recorder.revisions.count == 1 })
        s.liveTextSent(upTo: 0, shownRevision: 0)
        #expect(recorder.sent.isEmpty)
        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world.")
    }

    // MARK: run lifecycle

    @Test func eachLiveRunTellsTheProcessorItStarts() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world."])
        let (s, _) = liveSession(processor, script: [final("hello world ")])
        try await s.start()
        #expect(processor.runStarts == 1)
        _ = try await s.stop()
        try await s.start()
        #expect(processor.runStarts == 2)
        _ = try await s.stop()
    }

    @Test func aRunThatIsNotLiveDoesNotAnnounceALiveRun() async throws {
        let processor = LivePassProcessor(live: false, answers: [:])
        let (s, _) = liveSession(processor, script: [final("hello world ")])
        try await s.start()
        _ = try await s.stop()
        #expect(processor.runStarts == 0)
    }

    @Test func aProcessorThatIsNotLiveCleansTheWholeTextAtTheStopAsBefore() async throws {
        let processor = LivePassProcessor(live: false, answers: ["hello world how are you": "Hello world, how are you?"])
        let (s, _) = liveSession(processor, script: [final("hello world "), final("how are you ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { recorder.commits.count == 2 })
        let entry = try #require(try await s.stop())
        #expect(processor.calls.isEmpty)
        #expect(processor.wholeTexts == ["hello world how are you"])
        #expect(entry.text == "Hello world, how are you?")
        #expect(recorder.revisions.isEmpty)
    }
}

@Suite struct LiveTranscriptRevisionTests {
    @Test func aRevisionReplacesTheRunTextItCoversAndTheRawTailFollows() {
        var live = LiveTranscript()
        live.apply(.commit(delta: "hello world "))
        live.apply(.commit(delta: "how are you"))
        live.apply(.replaceVolatile(" and"))
        live.apply(.revise(TranscriptRevision(n: 1, start: 0, raw: "hello world ", text: "Hello world. ")))
        #expect(live.committed == "hello world how are you", "committed stays the raw text")
        #expect(live.revisedCommitted == "Hello world. how are you")
        #expect(live.text == "Hello world. how are you and")
    }

    @Test func aNewerRevisionReplacesTheEarlierOne() {
        var live = LiveTranscript()
        live.apply(.commit(delta: "one two "))
        live.apply(.revise(TranscriptRevision(n: 1, start: 0, raw: "one ", text: "One. ")))
        live.apply(.revise(TranscriptRevision(n: 2, start: 0, raw: "one two ", text: "One, two. ")))
        #expect(live.revisedCommitted == "One, two. ")
    }

    @Test func aRevisionAfterABoundaryKeepsTheRawTextBeforeIt() {
        var live = LiveTranscript()
        live.apply(.commit(delta: "one two "))
        live.apply(.revise(TranscriptRevision(n: 1, start: 4, raw: "two ", text: "Two. ")))
        #expect(live.revisedCommitted == "one Two. ")
    }

    @Test func aRevisionThatDoesNotMatchTheRawTextIsIgnored() {
        var live = LiveTranscript()
        live.apply(.commit(delta: "hello world"))
        live.apply(.revise(TranscriptRevision(n: 1, start: 0, raw: "goodbye", text: "Goodbye.")))
        #expect(live.revisedCommitted == "hello world")
    }

    @Test func cleaningKeepsTheRawSpansWhitespace() {
        #expect(TranscriptRevision.cleaning(" um hi there \n", n: 2, at: 3, to: "Hi there.")
            == TranscriptRevision(n: 2, start: 3, raw: " um hi there \n", text: " Hi there. \n"))
    }
}

@MainActor
@Suite struct LiveCleanupCoordinatorTests {
    private func rig(_ processor: LivePassProcessor, script: [TranscriptEvent]) -> (DictationCoordinator, FakeSink, FakeClipboard, FakeEngine) {
        let log = EventLog()
        let engine = FakeEngine(log: log)
        engine.set(script: script)
        let history = MemoryHistory()
        let clipboard = FakeClipboard(log: log)
        let coordinator = DictationCoordinator(
            activity: FakeActivity(log: log), clipboard: clipboard, readiness: FakeReadiness(),
            history: history,
            makeSession: { _, _ in
                DictationSession(
                    engine: engine, source: FakeSource(log: log), sessionControl: FakeSessionControl(log: log),
                    history: history, postProcessor: processor)
            })
        let sink = FakeSink(log: log)
        coordinator.sink = sink
        return (coordinator, sink, clipboard, engine)
    }

    @Test func theSinkHearsEachRevisionAndPassBeforeTheRunEnds() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world."])
        let (coordinator, sink, _, _) = rig(processor, script: [final("hello world ")])
        #expect(await coordinator.toggle() == .started)
        #expect(await eventually { sink.revisions.count == 1 })
        #expect(await coordinator.toggle() == .stopped("Hello world."))
        #expect(sink.revisions == [TranscriptRevision(n: 1, start: 0, raw: "hello world ", text: "Hello world. ")])
        let outcomes: [LivePassReport.Outcome] = sink.liveTrace.compactMap { if case .pass(let p) = $0 { p.outcome } else { nil } }
        #expect(outcomes == [.published])
        #expect(sink.ended.last?.committed == "hello world ", "the run's committed text stays raw")
        #expect(sink.ended.last?.text == "Hello world.")
    }

    @Test func theSentTentativeTextReachesTheSessionThroughTheSink() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world.", "you": "You?"])
        let (coordinator, sink, clipboard, engine) = rig(processor, script: [])
        #expect(await coordinator.toggle() == .started)
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { sink.revisions.count == 1 })
        let runID = try #require(sink.started.last?.id.uuidString)
        sink.tentative = "how are"
        coordinator.liveTextSent(runID: runID, upTo: 12, shownRevision: 1)
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { sink.revisions.count == 2 })
        #expect(sink.revisions.last?.start == 20)
        #expect(await coordinator.toggle() == .stopped("Hello world. how are You?"))
        #expect(clipboard.written.isEmpty)
    }

    @Test func aSendReportedWhileTheRunEndsStillKeepsTheClipboardUntouched() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world."])
        let (coordinator, sink, clipboard, engine) = rig(processor, script: [])
        sink.finalApplied = false
        #expect(await coordinator.toggle() == .started)
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { sink.revisions.count == 1 })
        let runID = try #require(sink.started.last?.id.uuidString)
        // The session is done; the keyboard's report arrives while the sink waits for the final state.
        sink.onRunEnded = { coordinator.liveTextSent(runID: runID, upTo: 12, shownRevision: 1) }
        #expect(await coordinator.toggle() == .stopped("Hello world."))
        #expect(clipboard.written.isEmpty, "the message was sent: nothing to copy")
    }

    @Test func aSentRunRebasesTheSessionAndNeverWritesTheClipboard() async throws {
        let processor = LivePassProcessor(answers: ["hello world": "Hello world.", "how are you": "How are you?"])
        let (coordinator, sink, clipboard, engine) = rig(processor, script: [])
        sink.finalApplied = false // the keyboard did not confirm (it was hidden after the send)
        #expect(await coordinator.toggle() == .started)
        engine.emit(final("hello world "), run: 0)
        #expect(await eventually { sink.revisions.count == 1 })
        let runID = try #require(sink.started.last?.id.uuidString)
        coordinator.liveTextSent(runID: "someone-else", upTo: 12, shownRevision: 1)
        #expect(sink.liveTrace.allSatisfy { if case .sent = $0 { false } else { true } }, "another run's boundary is ignored")
        coordinator.liveTextSent(runID: runID, upTo: 12, shownRevision: 1)
        engine.emit(final("how are you "), run: 0)
        #expect(await eventually { sink.revisions.count == 2 })
        #expect(await coordinator.toggle() == .stopped("Hello world. How are you?"))
        #expect(clipboard.written.isEmpty, "a sent run is never copied")
    }
}
