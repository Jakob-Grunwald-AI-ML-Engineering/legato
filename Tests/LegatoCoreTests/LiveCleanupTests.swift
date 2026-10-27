import Foundation
import Synchronization
import Testing
@testable import LegatoCore

/// A live-cleaning post-processor: answers each segment from a table (a missing entry throws), can hold a
/// segment until released, and records every call, how many ran at once and which were cancelled.
final class LiveSegmentProcessor: TranscriptPostProcessor {
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
    private let answers: [String: String]
    private let state = Mutex(State())

    init(live: Bool = true, answers: [String: String], hold: Set<String> = [], stopLimit: Duration? = nil) {
        cleansSegmentsLive = live
        liveStopTimeLimit = stopLimit
        self.answers = answers
        state.withLock { $0.held = hold }
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
        guard let out = answers[text] else { throw TestError(tag: "no answer") }
        return out
    }

    func processSegment(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> String {
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
        guard let out = answers[text] else { throw TestError(tag: "no answer") }
        return out
    }
}

/// Collects a session's edits as they are published.
@MainActor
final class LiveEditRecorder {
    private(set) var edits: [TranscriptEdit] = []
    private var task: Task<Void, Never>?

    init(_ session: DictationSession) {
        let stream = session.edits
        task = Task { [weak self] in
            for await edit in stream { self?.edits.append(edit) }
        }
    }

    var revisions: [TranscriptRevision] {
        edits.compactMap { if case .revise(let r) = $0 { r } else { nil } }
    }

    var commits: [String] {
        edits.compactMap { if case .commit(let d) = $0 { d } else { nil } }
    }
}

@MainActor
private func liveSession(
    _ processor: LiveSegmentProcessor, script: [TranscriptEvent] = [], deadline: Deadline = Deadline()
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
    @Test func eachFinalSegmentIsCleanedAndRevisedInOrder() async throws {
        let processor = LiveSegmentProcessor(answers: ["hello world": "Hello world.", "how are you": "How are you?"])
        let (s, _) = liveSession(processor, script: [final("hello world "), final("how are you ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(recorder.revisions == [
            TranscriptRevision(start: 0, raw: "hello world ", text: "Hello world. "),
            TranscriptRevision(start: 12, raw: "how are you ", text: "How are you? "),
        ])
        // The previously cleaned text is the next segment's context.
        #expect(processor.calls == [
            .init(text: "hello world", context: "", atStop: false),
            .init(text: "how are you", context: "Hello world.", atStop: false),
        ])

        let entry = try #require(try await s.stop())
        #expect(entry.text == "Hello world. How are you?")
        #expect(entry.rawText == "hello world how are you")
        #expect(processor.calls.count == 2, "nothing was left for the stop")
        #expect(processor.wholeTexts.isEmpty, "a live run never cleans the whole text again")
    }

    @Test func segmentsAreCleanedOneAtATime() async throws {
        let processor = LiveSegmentProcessor(answers: ["one": "One.", "two": "Two."], hold: ["one"])
        let (s, _) = liveSession(processor, script: [final("one "), final("two ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(processor.calls.count == 1, "the second segment waits for the first")

        processor.release("one")
        #expect(await eventually { recorder.revisions.count == 2 })
        #expect(processor.maxActive == 1)
        #expect(recorder.revisions.map(\.start) == [0, 4])
        _ = try await s.stop()
    }

    @Test func aSlowSegmentNeverHoldsBackRecognition() async throws {
        let processor = LiveSegmentProcessor(answers: ["one": "One."], hold: ["one"])
        let (s, _) = liveSession(
            processor, script: [final("one "), final("two "), TranscriptEvent(text: "thr", isFinal: false)])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { recorder.commits == ["one ", "two "] && recorder.edits.last == .replaceVolatile("thr") })
        #expect(recorder.revisions.isEmpty, "the first segment is still being cleaned")
        processor.release("one")
        _ = try await s.stop()
    }

    @Test func theStopCleansOnlyTheSegmentsNotCleanedYetInOnePass() async throws {
        let processor = LiveSegmentProcessor(
            answers: ["one": "One.", "two three": "Two, three."], hold: ["one"])
        let (s, _) = liveSession(processor, script: [final("one "), final("two "), final("three ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 && recorder.commits.count == 3 })

        let stop = Task { try await s.stop() }
        #expect(await eventually { s.runState == .finishing })
        processor.release("one") // the segment in flight finishes; the rest goes in the stop pass
        let entry = try #require(try await stop.value)

        #expect(processor.calls == [
            .init(text: "one", context: "", atStop: false),
            .init(text: "two three", context: "One.", atStop: true),
        ])
        #expect(recorder.revisions == [
            TranscriptRevision(start: 0, raw: "one ", text: "One. "),
            TranscriptRevision(start: 4, raw: "two three ", text: "Two, three. "),
        ])
        #expect(entry.text == "One. Two, three.")
        #expect(entry.rawText == "one two three")
    }

    @Test func aSegmentWhoseCleanupFailsKeepsItsRawTextAndTheNextOneGoesOn() async throws {
        let processor = LiveSegmentProcessor(answers: ["how are you": "How are you?"])
        let (s, _) = liveSession(processor, script: [final("hello world "), final("how are you ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { recorder.revisions.count == 1 })
        #expect(recorder.revisions == [TranscriptRevision(start: 12, raw: "how are you ", text: "How are you? ")])
        #expect(processor.calls.last?.context == "hello world")
        let entry = try #require(try await s.stop())
        #expect(entry.text == "hello world How are you?")
        #expect(entry.rawText == "hello world how are you")
    }

    @Test func anUnchangedRunHasNoRawText() async throws {
        let processor = LiveSegmentProcessor(answers: ["Hello.": "Hello."])
        let (s, _) = liveSession(processor, script: [final("Hello. ")])
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 })
        let entry = try #require(try await s.stop())
        #expect(recorder.revisions.isEmpty)
        #expect(entry.text == "Hello.")
        #expect(entry.rawText == nil)
    }

    @Test func anAbortCancelsTheCleanupInFlightAndRevisesNothing() async throws {
        let processor = LiveSegmentProcessor(answers: ["hello world": "Hello world."], hold: ["hello world"])
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

    @Test func theStopGivesUpOnTheSegmentInFlightAtTheTimeLimit() async throws {
        let processor = LiveSegmentProcessor(
            answers: ["one": "One.", "two three": "Two, three."], hold: ["one"], stopLimit: .seconds(3))
        let deadline = Deadline()
        let (s, _) = liveSession(processor, script: [final("one "), final("two "), final("three ")], deadline: deadline)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 && recorder.commits.count == 3 })

        let stop = Task { try await s.stop() }
        #expect(await eventually { deadline.asked == [.seconds(3)] }, "one deadline, the setting's time limit")
        deadline.fire()
        #expect(await eventually { s.runState == .idle }, "the stop ends at the deadline")
        processor.release("one")
        let entry = try #require(try await stop.value)

        #expect(entry.text == "one two three", "nothing was cleaned in time: all raw")
        #expect(entry.rawText == nil)
        #expect(processor.cancelled == ["one"])
        #expect(processor.calls.map(\.text) == ["one"], "no stop pass after the deadline")
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.revisions.isEmpty)
    }

    @Test func theStopPassIsCutAtTheSameDeadlineAndTheTailStaysRaw() async throws {
        let processor = LiveSegmentProcessor(
            answers: ["one": "One.", "two three": "Two, three."], hold: ["one", "two three"], stopLimit: .seconds(3))
        let deadline = Deadline()
        let (s, _) = liveSession(processor, script: [final("one "), final("two "), final("three ")], deadline: deadline)
        let recorder = LiveEditRecorder(s)
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 && recorder.commits.count == 3 })

        let stop = Task { try await s.stop() }
        #expect(await eventually { s.runState == .finishing })
        processor.release("one")
        #expect(await eventually { processor.calls.count == 2 }, "the stop pass started")
        deadline.fire()
        #expect(await eventually { s.runState == .idle })
        processor.release("two three")
        let entry = try #require(try await stop.value)

        #expect(entry.text == "One. two three")
        #expect(entry.rawText == "one two three")
        #expect(processor.cancelled == ["two three"])
        #expect(deadline.asked == [.seconds(3)], "one deadline for the whole stop, not one per pass")
        #expect(recorder.revisions == [TranscriptRevision(start: 0, raw: "one ", text: "One. ")])
    }

    @Test func aStopThatFinishesInTimeKeepsEverything() async throws {
        let processor = LiveSegmentProcessor(
            answers: ["one": "One.", "two three": "Two, three."], hold: ["one"], stopLimit: .seconds(3))
        let (s, _) = liveSession(processor, script: [final("one "), final("two "), final("three ")])
        try await s.start()
        #expect(await eventually { processor.calls.count == 1 })
        let stop = Task { try await s.stop() }
        #expect(await eventually { s.runState == .finishing })
        processor.release("one")
        let entry = try #require(try await stop.value)
        #expect(entry.text == "One. Two, three.")
        #expect(processor.cancelled.isEmpty)
    }

    @Test func eachLiveRunTellsTheProcessorItStarts() async throws {
        let processor = LiveSegmentProcessor(answers: ["hello world": "Hello world."])
        let (s, _) = liveSession(processor, script: [final("hello world ")])
        try await s.start()
        #expect(processor.runStarts == 1)
        _ = try await s.stop()
        try await s.start()
        #expect(processor.runStarts == 2)
        _ = try await s.stop()
    }

    @Test func aRunThatIsNotLiveDoesNotAnnounceALiveRun() async throws {
        let processor = LiveSegmentProcessor(live: false, answers: [:])
        let (s, _) = liveSession(processor, script: [final("hello world ")])
        try await s.start()
        _ = try await s.stop()
        #expect(processor.runStarts == 0)
    }

    @Test func aProcessorThatIsNotLiveCleansTheWholeTextAtTheStopAsBefore() async throws {
        let processor = LiveSegmentProcessor(live: false, answers: ["hello world how are you": "Hello world, how are you?"])
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
    @Test func aRevisionReplacesItsSpanInTheText() {
        var live = LiveTranscript()
        live.apply(.commit(delta: "hello world "))
        live.apply(.commit(delta: "how are you"))
        live.apply(.replaceVolatile(" and"))
        live.apply(.revise(TranscriptRevision(start: 0, raw: "hello world ", text: "Hello world. ")))
        #expect(live.committed == "hello world how are you", "committed stays the raw text")
        #expect(live.revisedCommitted == "Hello world. how are you")
        #expect(live.text == "Hello world. how are you and")
    }

    @Test func aRevisionThatDoesNotMatchTheRawTextIsIgnored() {
        var live = LiveTranscript()
        live.apply(.commit(delta: "hello world"))
        live.apply(.revise(TranscriptRevision(start: 0, raw: "goodbye", text: "Goodbye.")))
        #expect(live.revisedCommitted == "hello world")
    }

    @Test func cleaningKeepsTheRawSpansWhitespace() {
        #expect(TranscriptRevision.cleaning(" um hi there \n", at: 3, to: "Hi there.")
            == TranscriptRevision(start: 3, raw: " um hi there \n", text: " Hi there. \n"))
    }
}

@MainActor
@Suite struct LiveCleanupCoordinatorTests {
    @Test func theSinkHearsEachRevisionBeforeTheRunEnds() async throws {
        let log = EventLog()
        let engine = FakeEngine(log: log)
        engine.set(script: [final("hello world ")])
        let processor = LiveSegmentProcessor(answers: ["hello world": "Hello world."])
        let history = MemoryHistory()
        let coordinator = DictationCoordinator(
            activity: FakeActivity(log: log), clipboard: FakeClipboard(log: log), readiness: FakeReadiness(),
            history: history,
            makeSession: { _, _ in
                DictationSession(
                    engine: engine, source: FakeSource(log: log), sessionControl: FakeSessionControl(log: log),
                    history: history, postProcessor: processor)
            })
        let sink = FakeSink(log: log)
        coordinator.sink = sink
        #expect(await coordinator.toggle() == .started)
        #expect(await eventually { sink.revisions.count == 1 })
        #expect(await coordinator.toggle() == .stopped("Hello world."))
        #expect(sink.revisions == [TranscriptRevision(start: 0, raw: "hello world ", text: "Hello world. ")])
        #expect(sink.ended.last?.committed == "hello world ", "the run's committed text stays raw")
        #expect(sink.ended.last?.text == "Hello world.")
    }
}
