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
