import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// The keyboard's executor over a proxy whose reads lag and show intermediate states.
@MainActor
struct FieldEditCoordinatorTests {
    let timers = ManualTimers()

    func coordinator(_ proxy: LaggingProxy) -> FieldEditCoordinator {
        FieldEditCoordinator(document: proxy, settleTimeout: .milliseconds(250), schedule: timers.schedule)
    }

    /// An automatic edit replacing `span` with `text`, based on the coordinator's current version.
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

    // MARK: Reads that lag past the timeout (blocker 1)

    @Test func writeWhoseReadLagsPastTheTimeoutLandsAndIsNotHandedBack() {
        let proxy = LaggingProxy("teh cat")
        let c = coordinator(proxy)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 7, "", " sat", origin: .asr, id: id), onOutcome: outcomes.record(id))
        #expect(outcomes.all[id] == [.executed])
        timers.advance(by: .milliseconds(260))  // the host has reported nothing yet
        #expect(outcomes.conflicts(id).isEmpty)
        proxy.deliverAll()
        c.sync()
        #expect(outcomes.all[id] == [.executed, .applied])
        #expect(proxy.text == "teh cat sat")
    }

    @Test func writeThatNeverReachesTheFieldFailsOnceAfterTheExtendedWait() {
        let proxy = LaggingProxy("teh cat")
        let c = coordinator(proxy)
        let outcomes = Outcomes()
        let id = UUID()
        proxy.drops = true
        c.submit(edit(c, 7, "", " sat", origin: .asr, id: id), onOutcome: outcomes.record(id))
        timers.advance(by: .milliseconds(260))
        #expect(outcomes.conflicts(id).isEmpty)  // stale: it may still land
        timers.advance(by: .milliseconds(260))
        #expect(outcomes.conflicts(id).map(\.reason) == [.verifyFailed])
        timers.advance(by: .seconds(2))
        c.sync()
        #expect(outcomes.conflicts(id).count == 1)
        #expect(!c.awaitsVerification)
    }

    @Test func keyboardGoingAwayBeforeALaggingReadLeavesTheWriteUnconfirmedNotFailed() {
        let proxy = LaggingProxy("teh cat")
        let c = coordinator(proxy)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 7, "", " sat", origin: .asr, id: id), onOutcome: outcomes.record(id))
        c.close()
        #expect(outcomes.conflicts(id).isEmpty)
        #expect(outcomes.all[id] == [.executed, .unconfirmed])
    }

    // MARK: Intermediate proxy states (blocker 3)

    @Test func intermediateStatesOfAPatchBeforeTheCaretConfirmItWithoutTaintingIt() {
        let proxy = LaggingProxy("abc def")  // caret at the end
        let c = coordinator(proxy)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 1, "b", "X", id: id), onOutcome: outcomes.record(id))
        #expect(proxy.text == "aXc def")
        while proxy.deliverNext() {
            c.sync()  // after the move, after the delete, after the insert, after the move back
            #expect(outcomes.conflicts(id).isEmpty)
        }
        #expect(outcomes.all[id] == [.executed, .applied])
        // Our own text is not the user's: a later automatic edit of it is not refused as tainted.
        let next = UUID()
        c.submit(edit(c, 1, "X", "Y", id: next), onOutcome: outcomes.record(next))
        proxy.deliverAll()
        c.sync()
        #expect(outcomes.all[next] == [.executed, .applied])
        #expect(proxy.text == "aYc def")
    }

    @Test func intermediateStatesOfAPatchAfterTheCaretNeverReset() {
        let proxy = LaggingProxy("abcdef", caret: 3)  // "abc|def"
        let c = coordinator(proxy)
        let outcomes = Outcomes()
        let id = UUID()
        c.submit(edit(c, 4, "e", "E", id: id), onOutcome: outcomes.record(id))
        while proxy.deliverNext() {
            c.sync()
            #expect(outcomes.conflicts(id).isEmpty)
        }
        #expect(outcomes.all[id] == [.executed, .applied])
        #expect(c.predicted.window == "abcdEf")
        #expect(c.predicted.caret == 3)
    }

    @Test func keyTypedWhileTheHostShowsOurInsertButNotOurMoveBackLandsAtTheRealCaret() {
        let proxy = LaggingProxy("abc def", caret: 3)  // "abc| def"
        let c = coordinator(proxy)
        let id = UUID()
        c.submit(edit(c, 1, "b", "X", id: id))
        // Reported: the move, the delete, the insert; not yet the move back (the caret still reads 2).
        for _ in 0..<3 { proxy.deliverNext() }
        c.sync()
        #expect(c.type("k") == .done)
        proxy.deliverAll()
        c.sync()
        #expect(proxy.text == "aXck def")
        #expect(c.predicted.window == proxy.text)
        #expect(c.predicted.caret == proxy.field.caret)
    }

    /// The word row, ↶ ↷ and two version swaps in a row while every read trails: the field returns to earlier
    /// texts on the way (A → B → A), which the reads show one state at a time.
    @Test func stackedUserEditsReturningToEarlierTextsStayAlignedWithTheField() {
        let proxy = LaggingProxy("the cat sat on")
        let c = coordinator(proxy)
        var traced: [String] = []
        c.trace = { traced.append($0) }
        func swap(_ from: String, _ to: String) {
            let edit = c.caretEdit(for: [.deleteBackward(from.count), .insert(to)])!
            #expect(c.write(edit, origin: .versions, lane: .user, keepsCaret: false) == .done)
        }
        #expect(c.apply(WordEdit(forward: 0, deleteCount: 2, insert: "only "), origin: .wordRow) == .done)
        #expect(c.apply(WordEdit(forward: 0, deleteCount: 5, insert: "on"), origin: .history) == .done)
        swap("the cat sat on", "teh cat sat on")
        swap("teh cat sat on", "the cat sat on")
        #expect(c.apply(WordEdit(forward: 0, deleteCount: 2, insert: "only "), origin: .history) == .done)
        #expect(proxy.text == "the cat sat only ")
        while proxy.deliverNext() {
            c.sync()
            #expect(c.predicted.window == proxy.text, "\(traced)")
        }
        timers.advance(by: .seconds(1))
        #expect(c.predicted.window == "the cat sat only ")
        #expect(c.predicted.caret == 17)
        #expect(!traced.contains { $0.contains("result=conflict") })
        // The next write plans on the real field.
        #expect(c.type("x") == .done)
        proxy.deliverAll()
        c.sync()
        #expect(proxy.text == "the cat sat only x")
        #expect(c.predicted.window == proxy.text)
    }

    // MARK: Typing mid-word during a pending edit (review 9)

    /// "the cat sat", caret after "ca"; an earlier write awaits its read, so a cleanup edit waits behind it.
    func midWordSetup() -> (LaggingProxy, FieldEditCoordinator, Outcomes) {
        let proxy = LaggingProxy("the cat sat", caret: 6)
        let c = coordinator(proxy)
        let outcomes = Outcomes()
        let first = UUID()
        c.submit(edit(c, 0, "t", "T", id: first), onOutcome: outcomes.record(first))
        #expect(c.awaitsVerification)
        return (proxy, c, outcomes)
    }

    @Test func keyTypedInsideTheWordAPendingEditRewritesHandsThatEditBackAsTheUsers() {
        let (proxy, c, outcomes) = midWordSetup()
        let pending = UUID()
        #expect(c.submit(edit(c, 4, "cat", "dog", id: pending), onOutcome: outcomes.record(pending)) == .waiting)
        #expect(c.type("r") == .done)
        proxy.deliverAll()
        c.sync()
        let conflicts = outcomes.conflicts(pending)
        #expect(conflicts.map(\.reason) == [.overlap])
        #expect(conflicts.first?.byUser == true)
        #expect(proxy.text == "The cart sat")
    }

    @Test func keyTypedInAnotherWordShiftsAPendingEditThatThenLandsInPlace() {
        let (proxy, c, outcomes) = midWordSetup()
        let pending = UUID()
        #expect(c.submit(edit(c, 8, "sat", "sit", id: pending), onOutcome: outcomes.record(pending)) == .waiting)
        #expect(c.type("r") == .done)
        proxy.deliverAll()
        c.sync()  // the earlier write and the key confirmed: the pending edit runs, shifted past the key
        proxy.deliverAll()
        c.sync()
        #expect(outcomes.all[pending] == [.executed, .applied])
        #expect(proxy.text == "The cart sit")
        #expect(proxy.field.caret == 7)  // after the key
    }

    // MARK: Word-row and history edits (review 6, 10)

    @Test func editDeletingMoreThanATruncatedWindowShowsIsRefusedAndWritesNothing() {
        let proxy = LaggingProxy("lo wor")  // the host shows only the end of "hello wor"
        let c = coordinator(proxy)
        let result = c.apply(WordEdit(forward: 0, deleteCount: 9, insert: "hello world "), origin: .wordRow)
        #expect(result == .refused(Conflict(.outOfWindow)))
        #expect(proxy.callCount == 0)
        #expect(proxy.text == "lo wor")
    }

    @Test func undoStepTheQueueRefusesGoesBackOnTheHistory() throws {
        var history = EditHistory()
        let at = Date()
        history.record(removed: "", inserted: "hello world", at: at, contextBefore: "hello world")
        let proxy = LaggingProxy("world")  // a truncated window: the step's text is not all visible
        let c = coordinator(proxy)
        let undone = history.undo(contextBefore: "hello world")
        let step = try #require(undone)
        guard case .edit(let edit) = step else { Issue.record("expected an edit step"); return }
        #expect(c.apply(edit, origin: .history) == .refused(Conflict(.outOfWindow)))
        history.revertUndo()  // what the keyboard does with a refused step
        #expect(history.canUndo)
        #expect(!history.canRedo)
        #expect(proxy.text == "world")
    }
}
