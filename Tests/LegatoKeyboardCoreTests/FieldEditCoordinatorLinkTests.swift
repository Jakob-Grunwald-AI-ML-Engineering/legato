import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// The keyboard's queue on the link (L6): it publishes its feed as one batch per host update, keeps the versions
/// the app's edits are based on mappable, takes a cleared field as a run boundary, and decides a contradicted
/// prediction in bounded time while keys keep arriving.
@MainActor
struct FieldEditCoordinatorLinkTests {
    let timers = ManualTimers()

    func coordinator(_ document: any FieldEditDocument) -> (FieldEditCoordinator, Trace) {
        let c = FieldEditCoordinator(document: document, settleTimeout: .milliseconds(250), schedule: timers.schedule)
        let trace = Trace()
        c.trace = { trace.lines.append($0) }
        return (c, trace)
    }

    final class Trace {
        var lines: [String] = []
        func contains(_ part: String) -> Bool { lines.contains { $0.contains(part) } }
    }

    final class Batches {
        var all: [(batch: FeedBatch, window: String)] = []
        var sink: (FeedBatch, String) -> Void { { [self] in all.append(($0, $1)) } }
        var events: [FeedEvent] { all.flatMap { $0.batch.entries.map(\.event) } }
    }

    final class Outcomes {
        var all: [UUID: [FieldEditCoordinator.Outcome]] = [:]
        func record(_ id: UUID) -> (FieldEditCoordinator.Outcome) -> Void { { [self] in all[id, default: []].append($0) } }
        func decided(_ id: UUID) -> Bool { (all[id] ?? []).contains { $0 != .executed } }
    }

    func edit(
        _ base: FieldVersion, _ location: Int, _ expect: String, _ text: String, origin: EditOrigin = .agent,
        session: UUID? = nil, id: UUID = UUID()
    ) -> EditTransaction {
        EditTransaction(
            id: id, origin: origin, owner: "run", base: base,
            steps: [EditStep(span: Span(location: location, length: expect.utf16.count), text: text, expect: expect)],
            session: session)
    }

    // MARK: Feed

    @Test func publishingStartsWithAResyncOfTheWindow() {
        let d = ManualDocument("hello")
        let (c, _) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        #expect(batches.all.count == 1)
        #expect(batches.all[0].batch.resync)
        #expect(batches.all[0].batch.window == "hello")
        #expect(batches.all[0].window == "hello")
    }

    /// A key, its read: one batch for the key's call (nothing confirmed yet: no entries, no batch) and one for the
    /// read that confirms it, carrying the keystroke as applied; never a batch per internal step.
    @Test func oneBatchPerHostUpdateWithTheConfirmedEvents() {
        let d = ManualDocument("hi")
        let (c, _) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        _ = c.type("!")
        d.report()
        c.sync()
        #expect(batches.all.count == 2)
        guard case .applied(_, .keystroke, _, _) = batches.all[1].batch.entries.first?.event else {
            Issue.record("no applied keystroke: \(batches.all.map(\.batch))")
            return
        }
        #expect(batches.all[1].window == "hi!")
        #expect(!batches.all[1].batch.resync)
    }

    /// The agent's edit is based on the batch it read; keys typed meanwhile land before it arrives. It is mapped
    /// through them and lands (with no publishing, an idle queue forgets the old version: out of window).
    @Test func anEditBasedOnAnOlderBatchStillLands() {
        let d = ManualDocument("teh cat")
        let (c, _) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        let read = batches.all[0].batch
        for key in [" ", "s", "a", "t"] {
            _ = c.type(key)
            d.report()
            c.sync()
        }
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(read.version, 1, "eh", "he", session: read.session, id: id), onOutcome: outcomes.record(id))
        d.report()
        c.sync()
        #expect(d.field.text == "the cat sat")
        #expect(outcomes.all[id] == [.executed, .applied])
    }

    // MARK: Throttle and mappable age (review L6 #1)

    /// The stream ticks every 33 ms; the feed goes out a few times a second, never once per tick, nothing lost and
    /// the latest state flushed when the interval ends.
    @Test func aThrottledFeedPublishesAFewBatchesASecondWithEveryEvent() {
        let d = ManualDocument("")
        let (c, _) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink, minInterval: .milliseconds(200))
        for _ in 0..<30 {
            _ = c.type("a")
            d.report()
            c.sync()
            timers.advance(by: .milliseconds(33))
        }
        timers.advance(by: .milliseconds(250))
        #expect(batches.all.count <= 7, "\(batches.all.count) batches in a second")
        #expect(batches.all.last?.window == String(repeating: "a", count: 30))
        let keys = batches.events.filter { if case .applied(_, .keystroke, _, _) = $0 { true } else { false } }
        #expect(keys.count == 30)
    }

    /// An outcome of the app's edit is not held back by the throttle: the app's stop waits for it.
    @Test func anAppEditsOutcomeIsPublishedAtOnce() {
        let d = ManualDocument("teh cat")
        let (c, _) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink, minInterval: .milliseconds(200))
        let read = batches.all[0].batch
        _ = c.type(" ")
        d.report()
        c.sync()
        let before = batches.all.count
        let id = UUID()
        c.submit(edit(read.version, 1, "eh", "he", session: read.session, id: id))
        d.report()
        c.sync()
        #expect(batches.all.count == before + 1)
        #expect(batches.events.contains { if case .applied(id, .agent, _, _) = $0 { true } else { false } })
    }

    /// What waits for the interval goes out at once when asked (a run's end), and nothing after publishing stops.
    @Test func aWaitingBatchIsFlushedOnRequestAndDroppedWhenPublishingStops() {
        let d = ManualDocument("")
        let (c, _) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink, minInterval: .milliseconds(200))
        _ = c.type("a")
        d.report()
        c.sync()
        #expect(batches.all.count == 1)
        c.flushFeed()
        #expect(batches.all.count == 2 && batches.all[1].window == "a")
        _ = c.type("b")
        d.report()
        c.sync()
        c.stopPublishing()
        timers.advance(by: .seconds(1))
        #expect(batches.all.count == 2)
    }

    /// Many batches within a long agent pass (100 in a second): the version the agent read at its start is still
    /// mappable; the history is bounded by age, not by a batch count.
    @Test func anEditBasedOnABatchFromASecondAgoLandsHoweverManyBatchesCameSince() {
        let d = ManualDocument("teh cat")
        let c = FieldEditCoordinator(document: d, settleTimeout: .milliseconds(250), schedule: timers.schedule, now: timers.clock)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        let read = batches.all[0].batch
        for _ in 0..<100 {
            _ = c.type("a")
            d.report()
            c.sync()
            timers.advance(by: .milliseconds(10))
        }
        #expect(batches.all.count > FieldEditCoordinator.linkedVersions)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(read.version, 1, "eh", "he", session: read.session, id: id), onOutcome: outcomes.record(id))
        d.report()
        c.sync()
        #expect(outcomes.all[id] == [.executed, .applied])
        #expect(d.field.text.hasPrefix("the cat"))
    }

    /// Past the age (and the count), an old base is out of window: the history stays bounded.
    @Test func aBaseOlderThanTheMappableAgeIsOutOfWindow() {
        let d = ManualDocument("teh cat")
        let c = FieldEditCoordinator(document: d, settleTimeout: .milliseconds(250), schedule: timers.schedule, now: timers.clock)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        let read = batches.all[0].batch
        for _ in 0..<(FieldEditCoordinator.linkedVersions + 10) {
            _ = c.type("a")
            d.report()
            c.sync()
            timers.advance(by: FieldEditCoordinator.linkedAge / 10)
        }
        #expect(c.submit(edit(read.version, 1, "eh", "he", session: read.session)) == .refused(Conflict(.outOfWindow)))
    }

    @Test func withoutPublishingAnOldBaseIsOutOfWindow() {
        let d = ManualDocument("teh cat")
        let (c, _) = coordinator(d)
        let base = c.predicted.version
        _ = c.type(" ")
        d.report()
        c.sync()
        #expect(c.submit(edit(base, 1, "eh", "he")) == .refused(Conflict(.outOfWindow)))
    }

    /// The host clears the field: the queue resets with `cleared`, published at once; the agent's edit based before
    /// it is handed back out of window, and the chunk that awaited its read fails with the field empty.
    @Test func aClearedFieldResetsWithClearedAndIsPublished() {
        let d = ManualDocument("hi there")
        let (c, trace) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        let read = batches.all[0].batch
        let outcomes = Outcomes()
        let chunk = UUID()
        c.submit(edit(c.predicted.version, 8, "", " you", origin: .asr, id: chunk), onOutcome: outcomes.record(chunk))
        d.field = CaretProxy("")
        d.report()
        c.fieldCleared()
        #expect(trace.contains("fe.reset reason=cleared"))
        #expect(batches.events.contains { if case .reset(.cleared, "", _) = $0 { true } else { false } })
        #expect(outcomes.all[chunk]?.last == .conflict(Conflict(.verifyFailed)))
        #expect(c.submit(edit(read.version, 0, "hi", "Hi", session: read.session)) == .refused(Conflict(.outOfWindow)))
        #expect(c.predicted.window == "")
    }

    /// A document whose host reports the clear while our write's calls run (re-entrant, as a chat app's send can).
    final class ClearingDocument: FieldEditDocument {
        var field: CaretProxy
        var documentID: String? = "clearing"
        var onExecute: (() -> Void)?
        init(_ text: String) { field = CaretProxy(text) }
        var contextBefore: String { field.before }
        var contextAfter: String { field.after }
        func execute(_ calls: [ProxyCall]) {
            field.run(calls)
            let hook = onExecute
            onExecute = nil
            hook?()
        }
    }

    /// The host clears the field while one of our writes executes: the clear is not lost, it is taken once the
    /// write's calls returned (a run boundary, published as `reset(cleared)`).
    @Test func aClearDuringAWriteIsTakenOnceTheWriteReturns() {
        let d = ClearingDocument("hi there")
        let (c, trace) = coordinator(d)
        let batches = Batches()
        c.publishFeed(to: batches.sink)
        d.onExecute = { [weak c] in
            d.field = CaretProxy("")
            c?.fieldCleared()
        }
        c.submit(edit(c.predicted.version, 8, "", " you", origin: .asr))
        #expect(trace.contains("fe.reset reason=cleared"))
        #expect(batches.events.contains { if case .reset(.cleared, _, _) = $0 { true } else { false } })
    }

    @Test func clearingAnEmptyPredictionDoesNothing() {
        let d = ManualDocument("")
        let (c, trace) = coordinator(d)
        c.fieldCleared()
        #expect(!trace.contains("fe.reset"))
    }

    // MARK: Contradiction deadline (carried L2 should-fix a)

    /// A chunk awaits its read when the host shows an empty field (a read nothing explains), and the user keeps
    /// typing every 100 ms: the final read still decides within two timeouts of the first contradicted key, so the
    /// unverified keys stay few and the cleanup edit waiting behind them is not held for as long as the user types.
    @Test func keysDuringAContradictionDoNotPostponeTheFinalSettle() {
        let d = ManualDocument("hello")
        let (c, trace) = coordinator(d)
        let outcomes = Outcomes()
        c.submit(edit(c.predicted.version, 5, "", " there", origin: .asr))
        d.reportedBefore = ""
        d.reportedAfter = ""
        c.sync()
        let cleanup = UUID()
        c.submit(edit(c.predicted.version, 0, "h", "H", origin: .liveCleanup, id: cleanup), onOutcome: outcomes.record(cleanup))
        #expect(!outcomes.decided(cleanup))
        var decidedAfter: Int?
        for tick in 0..<20 {
            _ = c.type("a")
            timers.advance(by: .milliseconds(100))
            if decidedAfter == nil, outcomes.decided(cleanup) { decidedAfter = (tick + 1) * 100 }
        }
        #expect(decidedAfter != nil)
        #expect((decidedAfter ?? .max) <= 600)
        #expect(trace.contains("fe.settle final=1"))
    }

    /// Keys without a contradiction keep moving the deadline as before: a write is never decided while its read is
    /// merely due.
    @Test func keysWithoutAContradictionStillMoveTheDeadline() {
        let d = ManualDocument("hi")
        let (c, trace) = coordinator(d)
        for _ in 0..<5 {
            _ = c.type("a")
            d.report()
            timers.advance(by: .milliseconds(100))
        }
        #expect(!trace.contains("fe.settle final=1"))
        #expect(d.field.text == "hiaaaaa")
    }
}
