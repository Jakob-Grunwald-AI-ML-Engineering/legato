import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// A document whose report the test sets by hand: the calls change `field` at once, the reads show
/// `reportedBefore` / `reportedAfter` until `report()`.
@MainActor
final class ManualDocument: FieldEditDocument {
    var field: CaretProxy
    var reportedBefore: String
    var reportedAfter: String
    var documentID: String? = "manual"

    init(_ text: String, caret: Int? = nil) {
        field = CaretProxy(text, caret: caret)
        reportedBefore = field.before
        reportedAfter = field.after
    }

    var contextBefore: String { reportedBefore }
    var contextAfter: String { reportedAfter }
    func execute(_ calls: [ProxyCall]) { field.run(calls) }
    func report() {
        reportedBefore = field.before
        reportedAfter = field.after
    }
}

/// The second-round review of the keyboard's executor: keystrokes are never lost or held, a lagging write is not
/// typed twice, a caret tap that equals one of our own states is not swallowed.
@MainActor
struct FieldEditCoordinatorReviewTests {
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

    func edit(
        _ c: FieldEditCoordinator, _ location: Int, _ expect: String, _ text: String,
        origin: EditOrigin = .liveCleanup, id: UUID = UUID()
    ) -> EditTransaction {
        EditTransaction(
            id: id, origin: origin, owner: "run", base: c.predicted.version,
            steps: [EditStep(span: Span(location: location, length: expect.utf16.count), text: text, expect: expect)])
    }

    final class Outcomes {
        var all: [UUID: [FieldEditCoordinator.Outcome]] = [:]
        func record(_ id: UUID) -> (FieldEditCoordinator.Outcome) -> Void {
            { [self] outcome in all[id, default: []].append(outcome) }
        }
        func conflicts(_ id: UUID) -> [Conflict] {
            (all[id] ?? []).compactMap { if case .conflict(let c) = $0 { c } else { nil } }
        }
    }

    // MARK: Keystrokes are never held or lost (blocker)

    /// "hi", Return; the host sends and clears the field before the proxy reports the Return: the read "" is none
    /// of our states. The next keys are typed in the call they arrive, and nothing hands them back later.
    @Test func keysAfterTheHostClearsTheFieldBeforeReportingReturnAreTypedAtOnce() {
        let document = ManualDocument("hi")
        let (c, _) = coordinator(document)
        #expect(c.type("\n") == .done)
        document.field = CaretProxy("")  // the host sends and clears
        document.report()
        c.sync()
        #expect(c.type("o") == .done)
        #expect(c.type("k") == .done)
        #expect(document.field.text == "ok")
        timers.advance(by: .milliseconds(600))
        #expect(document.field.text == "ok")
        document.report()
        c.sync()
        #expect(document.field.text == "ok")
        #expect(c.predicted.window == "ok")
        #expect(!c.hasPending)
    }

    /// A transient empty read while a patch awaits its read: the key is typed at once, not handed back.
    @Test func keyTypedWhileAReadShowsAnEmptyFieldIsTypedAtOnce() {
        let document = ManualDocument("hello world")
        let (c, _) = coordinator(document)
        c.submit(edit(c, 0, "h", "H"))
        document.reportedBefore = ""
        document.reportedAfter = ""
        c.sync()
        #expect(c.type("!") == .done)
        #expect(document.field.text == "Hello world!")
        timers.advance(by: .milliseconds(600))
        document.report()
        c.sync()
        #expect(document.field.text == "Hello world!")
        #expect(c.predicted.window == "Hello world!")
    }

    /// A read nothing explains (the host replaced the field) does not hold the delete key either.
    @Test func deleteKeyWhileAReadIsUnexplainedIsTypedAtOnce() {
        let document = ManualDocument("hello")
        let (c, _) = coordinator(document)
        #expect(c.type("!") == .done)
        document.field = CaretProxy("abc")
        document.report()
        c.sync()
        #expect(c.deleteBackward() == .done)
        #expect(document.field.text == "ab")
        timers.advance(by: .milliseconds(600))
        document.report()
        c.sync()
        #expect(document.field.text == "ab")
        #expect(c.predicted.window == "ab")
    }

    // MARK: A write whose read lags past both waits (should-fix 2)

    /// " sat" lands, but its read lags 520 ms: the write fails and its source types it again at once. The late
    /// read shows the first copy: it is that write landing, so the retype is not typed again.
    @Test func retypeOfAWriteWhoseReadArrivesLateIsNotTypedTwice() {
        let proxy = LaggingProxy("teh cat")
        let (c, _) = coordinator(proxy)
        let outcomes = Outcomes()
        let first = UUID()
        c.submit(edit(c, 7, "", " sat", origin: .asr, id: first), onOutcome: outcomes.record(first))
        timers.advance(by: .milliseconds(520))
        #expect(outcomes.conflicts(first).map(\.reason) == [.verifyFailed])
        let retype = UUID()
        c.submit(edit(c, c.predicted.caret, "", " sat", origin: .asr, id: retype), onOutcome: outcomes.record(retype))
        proxy.deliverAll()
        c.sync()
        timers.advance(by: .seconds(1))
        c.sync()
        #expect(proxy.text == "teh cat sat")
        #expect(c.predicted.window == "teh cat sat")
        #expect(outcomes.all[retype]?.last == .applied)
        #expect(c.predicted.tainted.isEmpty)
    }

    /// The same, with the late read arriving before the source types it again: the read is that write landing,
    /// and the retype (planned on the field before it) is not typed again.
    @Test func lateReadBeforeTheRetypeIsThatWriteLanding() {
        let proxy = LaggingProxy("teh cat")
        let (c, _) = coordinator(proxy)
        let outcomes = Outcomes()
        let first = UUID()
        c.submit(edit(c, 7, "", " sat", origin: .asr, id: first), onOutcome: outcomes.record(first))
        timers.advance(by: .milliseconds(520))
        #expect(outcomes.conflicts(first).map(\.reason) == [.verifyFailed])
        proxy.deliverAll()
        c.sync()
        let retype = UUID()
        c.submit(edit(c, c.predicted.caret, "", " sat", origin: .asr, id: retype), onOutcome: outcomes.record(retype))
        timers.advance(by: .seconds(1))
        c.sync()
        #expect(proxy.text == "teh cat sat")
        #expect(c.predicted.window == "teh cat sat")
        #expect(c.predicted.tainted.isEmpty)
    }

    /// A write the field really lost: its retype is held for its own two waits; the field still shows nothing
    /// of either, so the retype runs its calls then: typed once, handed back once only.
    @Test func retypeOfAWriteTheFieldLostIsTypedOnce() {
        let proxy = LaggingProxy("teh cat")
        let (c, _) = coordinator(proxy)
        let outcomes = Outcomes()
        let first = UUID()
        proxy.drops = true
        c.submit(edit(c, 7, "", " sat", origin: .asr, id: first), onOutcome: outcomes.record(first))
        timers.advance(by: .milliseconds(520))
        proxy.drops = false
        let retype = UUID()
        c.submit(edit(c, c.predicted.caret, "", " sat", origin: .asr, id: retype), onOutcome: outcomes.record(retype))
        #expect(proxy.text == "teh cat")  // held: the first one may still land
        timers.advance(by: .milliseconds(520))
        #expect(proxy.text == "teh cat sat")
        proxy.deliverAll()
        c.sync()
        timers.advance(by: .seconds(1))
        #expect(proxy.text == "teh cat sat")
        #expect(outcomes.conflicts(first).count == 1)
        #expect(outcomes.all[retype] == [.executed, .applied])
    }

    /// A read lagging past the held retype's waits too: the retype runs and the late copy doubles the text.
    /// That is logged (`fe.duplicate`) rather than guessed away.
    @Test func aWriteLandingAfterItsHeldRetypeRanIsLoggedAsADuplicate() {
        let proxy = LaggingProxy("teh cat")
        let (c, trace) = coordinator(proxy)
        c.submit(edit(c, 7, "", " sat", origin: .asr))
        timers.advance(by: .milliseconds(520))
        c.submit(edit(c, c.predicted.caret, "", " sat", origin: .asr))
        timers.advance(by: .milliseconds(520))
        proxy.deliverAll()
        c.sync()
        #expect(proxy.text == "teh cat sat sat")
        #expect(trace.contains("fe.duplicate"))
    }

    // MARK: A caret tap equal to one of our states (should-fix 3)

    /// The user taps right after our patch's text ("aX|c def"), which is also the field before our move back.
    /// The key lands at the tap, and the prediction follows the field.
    @Test func keyAfterATapEqualToOurStateBeforeTheMoveBackFollowsTheField() {
        let proxy = LaggingProxy("abc def")
        let (c, _) = coordinator(proxy)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 1, "b", "X", id: id), onOutcome: outcomes.record(id))
        proxy.moveCaret(to: 2)
        c.sync()
        #expect(c.type("k") == .done)
        proxy.deliverAll()
        c.sync()
        timers.advance(by: .milliseconds(600))
        c.sync()
        #expect(proxy.text == "aXkc def")
        #expect(c.predicted.window == proxy.text)
        #expect(c.predicted.caret == proxy.field.caret)
        #expect(outcomes.all[id]?.last == .applied)
    }

    /// A word-row edit after such a tap is never planned on the predicted text (which has the caret elsewhere):
    /// it is refused and writes nothing.
    @Test func wordRowEditAfterATapEqualToOurStateIsNotPlannedOnTheWrongText() {
        let proxy = LaggingProxy("abc def")
        let (c, _) = coordinator(proxy)
        c.submit(edit(c, 1, "b", "X"))
        proxy.moveCaret(to: 2)
        c.sync()
        let calls = proxy.callCount
        #expect(c.apply(WordEdit(forward: 0, deleteCount: 2, insert: "zz"), origin: .wordRow) == .refused(Conflict(.outOfWindow)))
        #expect(proxy.callCount == calls)
        #expect(proxy.text == "aXc def")
    }

    /// A version swap (user lane) after such a tap is refused too.
    @Test func versionSwapAfterATapEqualToOurStateIsRefused() {
        let proxy = LaggingProxy("abc def")
        let (c, _) = coordinator(proxy)
        c.submit(edit(c, 1, "b", "X"))
        proxy.moveCaret(to: 2)
        c.sync()
        let calls = proxy.callCount
        let swap = c.caretEdit(for: [.deleteBackward(3), .insert("DEF")])!
        #expect(c.write(swap, origin: .versions, lane: .user, keepsCaret: false) == .refused(Conflict(.outOfWindow)))
        #expect(proxy.callCount == calls)
    }
}
