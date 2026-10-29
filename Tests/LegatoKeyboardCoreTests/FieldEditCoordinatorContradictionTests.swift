import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// The third-round review of the keyboard's executor: keys typed while a read contradicts the prediction go
/// through the queue (user lane, at the predicted caret), so an old read never makes it forget them and a later
/// read never takes them for the user's typing that fails an earlier write.
@MainActor
struct FieldEditCoordinatorContradictionTests {
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

    final class Outcomes {
        var all: [UUID: [FieldEditCoordinator.Outcome]] = [:]
        func record(_ id: UUID, then: ((FieldEditCoordinator.Outcome) -> Void)? = nil) -> (FieldEditCoordinator.Outcome) -> Void {
            { [self] outcome in
                all[id, default: []].append(outcome)
                then?(outcome)
            }
        }
        func failed(_ id: UUID) -> Bool {
            (all[id] ?? []).contains { if case .conflict = $0 { true } else { false } }
        }
    }

    func edit(
        _ c: FieldEditCoordinator, _ location: Int, _ expect: String, _ text: String,
        origin: EditOrigin = .liveCleanup, id: UUID = UUID()
    ) -> EditTransaction {
        EditTransaction(
            id: id, origin: origin, owner: "run", base: c.predicted.version,
            steps: [EditStep(span: Span(location: location, length: expect.utf16.count), text: text, expect: expect)])
    }

    /// An ASR chunk whose source types it again at the caret when it fails (as the controller's rewind does).
    func chunk(_ c: FieldEditCoordinator, _ text: String, _ outcomes: Outcomes, id: UUID = UUID()) -> UUID {
        c.submit(edit(c, c.predicted.caret, "", text, origin: .asr, id: id), onOutcome: outcomes.record(id) { [weak c] outcome in
            guard let c, case .conflict(let conflict) = outcome, conflict.reason == .verifyFailed else { return }
            _ = chunk(c, text, outcomes)
        })
        return id
    }

    func empty(_ d: ManualDocument) {
        d.reportedBefore = ""
        d.reportedAfter = ""
    }

    // MARK: A. An old read never makes the queue forget a key

    /// "hello" + cleanup h→H; a read ""; "!" (field "Hello!"); the old read "Hello"; a word-row edit planned on
    /// "Hello". It is refused (or lands on "Hello"), never planned at the wrong caret ("Heowdy").
    @Test func aWordRowEditAfterAnOldReadIsNotPlannedAtTheWrongCaret() {
        let d = ManualDocument("hello")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 0, "h", "H", id: id), onOutcome: outcomes.record(id))
        empty(d)
        c.sync()
        #expect(c.type("!") == .done)
        #expect(d.field.text == "Hello!")
        d.reportedBefore = "Hello"
        c.sync()
        let result = c.apply(WordEdit(forward: 0, deleteCount: 5, insert: "Howdy"), origin: .wordRow)
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        d.report()
        c.sync()
        if result == .refused(Conflict(.outOfWindow)) {
            #expect(d.field.text == "Hello!")
        } else {
            #expect(["Howdy", "Howdy!"].contains(d.field.text))
        }
        #expect(c.predicted.window == d.field.text)
        #expect(outcomes.all[id]?.last == .applied)
    }

    /// "teh cat" + cleanup c→C; a read ""; "s"; the old read "teh Cat"; the cleanup teh→the: "the Cats".
    @Test func aCleanupAfterAnOldReadIsWrittenAfterTheKey() {
        let d = ManualDocument("teh cat")
        let (c, _) = coordinator(d)
        c.submit(edit(c, 4, "c", "C"))
        empty(d)
        c.sync()
        #expect(c.type("s") == .done)
        d.reportedBefore = "teh Cat"
        c.sync()
        c.submit(edit(c, 0, "teh", "the"))
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))  // a read held back for a retype that did not come
        #expect(d.field.text == "the Cats")
        #expect(c.predicted.window == "the Cats")
    }

    /// The same with the host reporting each write promptly: both cleanups are confirmed, none fails.
    @Test func aCleanupAfterAnOldReadIsConfirmedWhenTheReadsKeepUp() {
        let d = ManualDocument("teh cat")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let first = UUID(), second = UUID()
        c.submit(edit(c, 4, "c", "C", id: first), onOutcome: outcomes.record(first))
        empty(d)
        c.sync()
        _ = c.type("s")
        d.reportedBefore = "teh Cat"
        c.sync()
        c.submit(edit(c, 0, "teh", "the", id: second), onOutcome: outcomes.record(second))
        d.report()
        c.sync()
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        #expect(d.field.text == "the Cats")
        #expect(outcomes.all[first]?.last == .applied)
        #expect(outcomes.all[second]?.last == .applied)
    }

    // MARK: B. A key is never taken for typing that fails a landed write

    /// "hi" + ASR " there"; a read ""; "!"; the old read "hi there"; the next chunk " you". Its source types a
    /// failed chunk again: the field never shows " you" twice.
    @Test func theNextChunkAfterAnOldReadIsTypedOnce() {
        let d = ManualDocument("hi")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        _ = chunk(c, " there", outcomes)
        empty(d)
        c.sync()
        _ = c.type("!")
        d.reportedBefore = "hi there"
        c.sync()
        _ = chunk(c, " you", outcomes)
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        d.report()
        c.sync()
        timers.advance(by: .seconds(1))
        d.report()
        c.sync()
        #expect(d.field.text == "hi there! you")
        #expect(c.predicted.window == "hi there! you")
    }

    /// The same with the host reporting each write promptly: no chunk fails.
    @Test func theNextChunkAfterAnOldReadIsConfirmedWhenTheReadsKeepUp() {
        let d = ManualDocument("hi")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let there = chunk(c, " there", outcomes)
        empty(d)
        c.sync()
        _ = c.type("!")
        d.reportedBefore = "hi there"
        c.sync()
        let you = chunk(c, " you", outcomes)
        d.report()
        c.sync()
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        #expect(d.field.text == "hi there! you")
        #expect(outcomes.all[there] == [.executed, .applied])
        #expect(outcomes.all[you] == [.executed, .applied])
    }

    /// "hello" + ASR " world"; a read ""; the delete key: "hello worl". The chunk landed: it is confirmed and
    /// never typed again.
    @Test func aDeleteKeyIntoAnUnconfirmedChunkConfirmsIt() {
        let d = ManualDocument("hello")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let world = chunk(c, " world", outcomes)
        empty(d)
        c.sync()
        #expect(c.deleteBackward() == .done)
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        c.sync()
        #expect(d.field.text == "hello worl")
        #expect(c.predicted.window == "hello worl")
        #expect(outcomes.all[world] == [.executed, .applied])
    }

    /// "hello wrold" + cleanup wrold→world; a read ""; the delete key: the revision landed and is confirmed (its
    /// source does not mark it skipped).
    @Test func aDeleteKeyAfterAnUnconfirmedRevisionConfirmsIt() {
        let d = ManualDocument("hello wrold")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 6, "wrold", "world", id: id), onOutcome: outcomes.record(id))
        empty(d)
        c.sync()
        #expect(c.deleteBackward() == .done)
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        c.sync()
        #expect(d.field.text == "hello worl")
        #expect(c.predicted.window == "hello worl")
        #expect(outcomes.all[id] == [.executed, .applied])
    }

    // MARK: Orderings of reads, keys and writes

    /// "hi", Return; the host sends and clears; "o"; then the host's old report of the Return; "k", " "; a word-row
    /// edit planned on what it last showed. It is refused (or lands on "ok "); the field ends as predicted.
    @Test func aStaleReportOfReturnAfterTheHostClearedKeepsTheKeys() {
        let d = ManualDocument("hi")
        let (c, _) = coordinator(d)
        _ = c.type("\n")
        d.field = CaretProxy("")
        d.report()
        c.sync()
        _ = c.type("o")
        d.reportedBefore = "hi\n"
        c.sync()
        _ = c.type("k")
        _ = c.type(" ")
        #expect(d.field.text == "ok ")
        let result = c.apply(WordEdit(forward: 0, deleteCount: 3, insert: "OK "), origin: .wordRow)
        d.report()
        c.sync()
        timers.advance(by: .milliseconds(600))
        d.report()
        c.sync()
        #expect(result == .refused(Conflict(.outOfWindow)) ? d.field.text == "ok " : d.field.text == "OK ")
        #expect(c.predicted.window == d.field.text)
    }

    /// Keys only: "c"; a read ""; "d", "e"; the host then reports each key in order. Every key stays known: the
    /// prediction is the field after each read, and nothing fails.
    @Test func keysReportedInOrderAfterAContradictionStayKnown() {
        let d = ManualDocument("ab")
        let (c, trace) = coordinator(d)
        _ = c.type("c")
        empty(d)
        c.sync()
        _ = c.type("d")
        _ = c.type("e")
        for shown in ["abc", "abcd", "abcde"] {
            d.reportedBefore = shown
            c.sync()
            #expect(c.predictedBefore == "abcde")
        }
        timers.advance(by: .seconds(1))
        #expect(d.field.text == "abcde")
        #expect(!c.awaitsVerification)
        #expect(!trace.contains("result=conflict"))
    }

    /// "hello" + ASR " world"; a read ""; three deletes ("hello wo"); the old reads of the chunk and the first
    /// delete keep the deletes known: the next key lands after them, and the chunk is confirmed.
    @Test func deletesIntoAChunkThenOldReadsKeepTheDeletes() {
        let d = ManualDocument("hello")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let world = chunk(c, " world", outcomes)
        empty(d)
        c.sync()
        for _ in 0..<3 { #expect(c.deleteBackward() == .done) }
        #expect(d.field.text == "hello wo")
        for shown in ["hello world", "hello worl"] {
            d.reportedBefore = shown
            c.sync()
            #expect(c.predictedBefore == "hello wo")
        }
        #expect(c.type("x") == .done)
        d.report()
        c.sync()
        timers.advance(by: .seconds(1))
        #expect(d.field.text == "hello wox")
        #expect(c.predicted.window == "hello wox")
        #expect(outcomes.all[world] == [.executed, .applied])
    }

    /// The host really clears the field (a send) while a chunk awaits its read; "o", "k": the field is "ok" and
    /// the prediction follows it; nothing is typed again.
    @Test func keysAfterTheHostClearsUnderAnUnconfirmedChunkAreNotFollowedByARetype() {
        let d = ManualDocument("hi")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        _ = chunk(c, " there", outcomes)
        d.field = CaretProxy("")
        d.report()
        c.sync()
        _ = c.type("o")
        _ = c.type("k")
        d.report()
        c.sync()
        timers.advance(by: .seconds(1))
        d.report()
        c.sync()
        #expect(d.field.text == "ok")
        #expect(c.predicted.window == "ok")
    }

    /// A transient empty read, keys, then the host reports everything after `lag`: within both waits nothing
    /// fails and the chunk is in the field once.
    @Test(arguments: [100, 300, 450])
    func aTransientEmptyReadThenLagFailsNothing(lag: Int) {
        let d = ManualDocument("hi")
        let (c, _) = coordinator(d)
        let outcomes = Outcomes()
        let there = chunk(c, " there", outcomes)
        empty(d)
        c.sync()
        _ = c.type("!")
        _ = c.type("?")
        timers.advance(by: .milliseconds(lag))
        d.report()
        c.sync()
        timers.advance(by: .seconds(1))
        #expect(d.field.text == "hi there!?")
        #expect(c.predicted.window == "hi there!?")
        #expect(outcomes.all[there] == [.executed, .applied])
    }

    /// Keys typed while contradicted are the queue's writes, not calls it does not know.
    @Test func keysWhileContradictedGoThroughTheQueue() {
        let d = ManualDocument("hello")
        let (c, trace) = coordinator(d)
        c.submit(edit(c, 0, "h", "H"))
        empty(d)
        c.sync()
        trace.lines = []
        _ = c.type("!")
        _ = c.deleteBackward()
        _ = c.type("?")
        #expect(d.field.text == "Hello?")
        #expect(c.predicted.window == "Hello?")
        #expect(trace.lines.filter { $0.hasPrefix("fe.write origin=keystroke") }.count == 3)
        #expect(c.awaitsVerification)
    }
}
