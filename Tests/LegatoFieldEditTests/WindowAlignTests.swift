import Foundation
import Testing
import LegatoFieldEdit

@Suite struct WindowAlignTests {
    let v0 = FieldVersion(0)

    private func queueWithPendingFix() -> (FieldEditQueue, EditTransaction) {
        var queue = FieldEditQueue(FieldSnapshot(before: "hello wo", after: "rld, teh end"))
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(13, "teh", with: "the")])
        queue.submit(fix)
        return (queue, fix)
    }

    @Test func caretOnlyMoveRebasesTheCaretExactly() {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "hello", after: " world, teh end"))
        #expect(queue.document.caret == 5)
        #expect(queue.document.version == v0)
        #expect(queue.feed.entries.isEmpty)
        let write = queue.next()
        #expect(write?.id == fix.id)
        #expect(write?.steps == [replace(13, "teh", with: "the")])
        #expect(write?.caret == 5)
    }

    @Test func aChangeAtTheCaretIsAForeignStep() {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "hello woXY", after: "rld, teh end"))
        #expect(queue.feed.entries.map(\.event) == [.foreign(.insert("XY", at: 8), byUser: true, version: FieldVersion(1))])
        #expect(queue.next()?.steps == [replace(15, "teh", with: "the")])
        #expect(queue.takeEvents().allSatisfy { if case .conflict(fix.id, _) = $0 { false } else { true } })
    }

    @Test(arguments: [
        ("the caret jumped elsewhere", FieldSnapshot(before: "another paragraph ", after: "entirely")),
    ])
    func anUnalignableWindowResets(_ name: String, _ snapshot: FieldSnapshot) {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(snapshot)
        #expect(queue.takeEvents() == [.conflict(fix.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.unaligned, window: snapshot.window, version: FieldVersion(1)))
        #expect(queue.document == ShadowDocument(window: snapshot.window, caret: snapshot.caret, version: FieldVersion(1)))
        #expect(queue.next() == nil)
    }

    @Test func aClearedFieldResets() {
        var (queue, fix) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "", after: ""))
        #expect(queue.takeEvents() == [.conflict(fix.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.cleared, window: "", version: FieldVersion(1)))
    }

    @Test func editsBasedBeforeAResetAreOutOfWindow() {
        var (queue, _) = queueWithPendingFix()
        queue.observe(FieldSnapshot(before: "another ", after: "field"))
        _ = queue.takeEvents()
        let late = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("x", at: 0)])
        queue.submit(late)
        #expect(queue.takeEvents() == [.conflict(late.id, Conflict(.outOfWindow))])
    }

    @Test func focusChangeFailsUnverifiedAndPendingEdits() {
        var (queue, fix) = queueWithPendingFix()
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("r", at: 8)])
        queue.submit(key)
        #expect(queue.next()?.id == key.id)
        queue.reset(FieldSnapshot(before: "", after: "new field"), reason: .focusChanged)
        #expect(queue.takeEvents() == [
            .conflict(key.id, Conflict(.focusLost)),
            .conflict(fix.id, Conflict(.focusLost)),
        ])
        #expect(queue.document.window == "new field")
        #expect(queue.document.caret == 0)
    }

    @Test func ownedAndTaintedSpansDoNotSurviveAReset() {
        var field = ""
        var queue = macQueue(field)
        queue.submit(EditTransaction(origin: .asr, owner: "run", base: v0, steps: [.insert("abc", at: 0)]))
        queue.drain(&field)
        #expect(!queue.document.owned.isEmpty)
        queue.reset(FieldSnapshot(window: "xyz", caret: 0, windowBase: 0), reason: .focusChanged)
        #expect(queue.document.owned.isEmpty)
        #expect(queue.document.windowBase == 0)
    }

    // MARK: Length-limited windows (B1)

    /// The proxy's context is length-limited, so the window's edges move with the caret's text: an edge shift
    /// re-bases offsets and taints nothing (this case used to be asserted as a reset).
    @Test func aShiftedWindowEdgeRebasesWithoutTaint() {
        var (queue, fix) = queueWithPendingFix()
        let snapshot = FieldSnapshot(before: "llo wo", after: "rld, teh end, and more")
        queue.observe(snapshot)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.feed.entries.map(\.event) == [.rebased(window: snapshot.window, shift: -2, version: FieldVersion(1))])
        #expect(queue.document.window == snapshot.window)
        #expect(queue.document.caret == 6)
        #expect(queue.document.tainted.isEmpty)
        let write = queue.next()
        #expect(write?.id == fix.id)
        #expect(write?.steps == [replace(11, "teh", with: "the")])
    }

    @Test func aSnapshotCarriesTheTextBeforeAndAfterTheCaret() {
        let snapshot = FieldSnapshot(window: "hello world", caret: 5, windowBase: 0)
        #expect(snapshot.before == "hello")
        #expect(snapshot.after == " world")
        #expect(FieldSnapshot(before: "ab", after: "c").caret == 2)
    }

    @Test func ourWriteThatShiftsTheWindowEdgeIsConfirmed() {
        var queue = FieldEditQueue(FieldSnapshot(before: "0123456789", after: ""))
        let fix = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [replace(4, "4", with: "four")])
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("ab", at: 10)])
        queue.submit(fix)
        queue.submit(key)
        #expect(queue.next()?.id == key.id)
        #expect(queue.settle(FieldSnapshot(before: "23456789ab", after: "")) == .confirmed)
        #expect(queue.takeEvents() == [.applied(key.id, version: FieldVersion(1))])
        #expect(queue.document.window == "23456789ab")
        #expect(queue.document.caret == 10)
        #expect(queue.document.tainted.isEmpty)
        #expect(queue.next()?.steps == [replace(2, "4", with: "four")])
    }

    @Test func aHostUpdateNotShowingEveryWriteYetWaitsForTheNext() {
        var queue = FieldEditQueue(FieldSnapshot(before: "one two", after: ""))
        let key1 = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("!", at: 7)])
        queue.submit(key1)
        _ = queue.next()
        let key2 = EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("?", at: 8)])
        queue.submit(key2)
        _ = queue.next()

        #expect(queue.settle(FieldSnapshot(before: "one two", after: ""), final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.settle(FieldSnapshot(before: "one two!", after: ""), final: false) == .notYet)
        #expect(queue.takeEvents() == [.applied(key1.id, version: FieldVersion(1))])
        #expect(queue.settle(FieldSnapshot(before: "one two!?", after: ""), final: false) == .confirmed)
        #expect(queue.takeEvents() == [.applied(key2.id, version: FieldVersion(2))])
        #expect(queue.document.window == "one two!?")
    }

    @Test func aHostUpdateThatContradictsTheWritesDivergesEvenWhileWaiting() {
        var queue = FieldEditQueue(FieldSnapshot(before: "one two", after: ""))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("!", at: 7)])
        queue.submit(key)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "one tw", after: ""), final: false) == .diverged)
        #expect(queue.takeEvents() == [.conflict(key.id, Conflict(.verifyFailed))])
        #expect(queue.document.window == "one tw")
        #expect(queue.feed.entries.last?.event == .foreign(replace(6, "o", with: ""), byUser: true, version: queue.document.version))
    }

    @Test func aLaggingReadWithAShiftedEdgeWaitsThenConfirms() {
        var queue = FieldEditQueue(FieldSnapshot(before: "0123456789", after: ""))
        let key1 = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("ab", at: 10)])
        queue.submit(key1)
        _ = queue.next()
        queue.submit(EditTransaction(origin: .keystroke, base: queue.document.version, steps: [.insert("c", at: 12)]))
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "23456789ab", after: ""), final: false) == .notYet)
        #expect(queue.settle(FieldSnapshot(before: "3456789abc", after: ""), final: false) == .confirmed)
        #expect(queue.document.window == "3456789abc")
    }

    // MARK: Ambiguous reads: never guess where the offsets went

    /// Rule 1: a read byte-identical to an older prediction that is also a newer prediction with a moved edge is
    /// either a lagging read or a landed write plus an edge shift; the two place pending offsets differently.
    /// It waits (`notYet`) and, final, resets: nothing pending is written at a guessed offset.
    @Test func aReadIdenticalToAnOlderPredictionAndAShiftOfANewerOneWaitsThenResets() {
        var queue = FieldEditQueue(FieldSnapshot(before: "aaaa", after: "bb"))
        let mark = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("!", at: 1)])
        queue.submit(mark)
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("a", at: 4)])
        queue.submit(key)
        #expect(queue.next()?.id == key.id)
        let read = FieldSnapshot(before: "aaaa", after: "bb")
        #expect(queue.settle(read, final: false) == .notYet)
        #expect(queue.takeEvents().isEmpty)
        #expect(queue.settle(read) == .diverged)
        #expect(queue.takeEvents() == [.conflict(key.id, Conflict(.verifyFailed)), .conflict(mark.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.unaligned, window: "aaaabb", version: queue.document.version))
        #expect(queue.next() == nil)
    }

    /// A read identical to the newest prediction is the writes landing as predicted: it confirms them even when
    /// an older prediction with a moved edge would also fit.
    @Test func aReadIdenticalToTheNewestPredictionConfirms() {
        var queue = FieldEditQueue(FieldSnapshot(before: "aa", after: ""))
        queue.submit(EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("!", at: 1)]))
        let key = EditTransaction(origin: .keystroke, base: v0, steps: [.insert("a", at: 2)])
        queue.submit(key)
        _ = queue.next()
        #expect(queue.settle(FieldSnapshot(before: "aaa", after: "")) == .confirmed)
        #expect(queue.takeEvents() == [.applied(key.id, version: FieldVersion(1))])
        #expect(queue.next()?.steps == [.insert("!", at: 1)])
    }

    /// Rule 2: a read that is the prediction plus typing and also the prediction with a moved edge confirms the
    /// write (it landed either way) and resets: a wrong edge shift would move the owned span onto the user's
    /// text, wrong typing would leave it on other text.
    @Test func aReadExplainedByTypingAndByAnEdgeShiftConfirmsTheWriteAndResets() {
        var queue = FieldEditQueue(FieldSnapshot(before: "", after: ""))
        let write = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("ab", at: 0)], caret: 2)
        queue.submit(write)
        _ = queue.next()
        let fix = EditTransaction(origin: .liveCleanup, owner: "run", base: queue.document.version, steps: [replace(0, "ab", with: "AB")])
        queue.submit(fix)
        #expect(queue.settle(FieldSnapshot(before: "ab ab", after: "")) == .confirmed)
        #expect(queue.takeEvents() == [.applied(write.id, version: FieldVersion(1)), .conflict(fix.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.unaligned, window: "ab ab", version: queue.document.version))
        #expect(queue.document.owned.isEmpty)
    }

    /// An edge shift only competes when there was text on both sides of the left edge: at the field's start a
    /// change at the caret is typing.
    @Test func typingAtTheStartOfTheWindowIsAForeignStep() {
        var queue = FieldEditQueue(FieldSnapshot(before: "", after: "x"))
        queue.submit(EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("!", at: 1)]))
        queue.observe(FieldSnapshot(before: "h", after: "x"))
        #expect(queue.feed.entries.map(\.event) == [.foreign(.insert("h", at: 0), byUser: true, version: FieldVersion(1))])
        #expect(queue.next()?.steps == [.insert("!", at: 2)])
    }

    /// Rule 3: "aa" → "a" is a user delete or the left edge moving by one; a pending edit before the caret would
    /// be one place off under the wrong one, so the queue resets and hands it back.
    @Test func aDeleteThatCouldBeAnEdgeShiftResets() {
        var queue = FieldEditQueue(FieldSnapshot(before: "aa", after: ""))
        let mark = EditTransaction(origin: .agent, owner: "run", base: v0, steps: [.insert("!", at: 0)])
        queue.submit(mark)
        queue.observe(FieldSnapshot(before: "a", after: ""))
        #expect(queue.takeEvents() == [.conflict(mark.id, Conflict(.outOfWindow))])
        #expect(queue.feed.entries.last?.event == .reset(.unaligned, window: "a", version: FieldVersion(1)))
        #expect(queue.next() == nil)
    }
}
