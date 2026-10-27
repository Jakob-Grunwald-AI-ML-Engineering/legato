import Foundation
import Testing
@testable import LegatoKeyboardCore

private func live(
    _ committed: String, _ volatile: String = "", revision: HostRevision? = nil, phase: HostPhase = .listening
) -> HostState {
    var state = hostState(phase: phase, committed: committed, volatile: volatile)
    state.delivery = .live
    state.revision = revision
    return state
}

private func at(_ ms: Double) -> Date { t0.addingTimeInterval(ms / 1000) }

/// The keyboard showed "hello world " for the run; the host emptied the field.
private func checkEmpty(_ watch: inout ClearWatch, at ms: Double) -> ClearWatch.Outcome {
    watch.check(
        state: live("hello world "), cursor: cursor(committedCount: 12), documentID: "doc-A", contextBefore: "",
        hasText: false, now: at(ms))
}

private func sentBase(_ outcome: ClearWatch.Outcome) -> Int? {
    if case .cleared(let sent) = outcome { sent?.sentBase } else { nil }
}

@Suite struct ClearWatchTests {
    @Test func aClearLongAfterTheKeyboardsOwnEditIsBelievedAtOnce() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        let outcome = checkEmpty(&watch, at: 400)
        #expect(sentBase(outcome) == 12)
    }

    @Test func aReturnTheKeyboardTypedNeverHoldsTheClearBack() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0)) // a typewriter tick just before
        watch.returnTyped(at: at(10))
        let outcome = checkEmpty(&watch, at: 20)
        #expect(sentBase(outcome) == 12, "the Return is the most likely send")
        #expect(!watch.holds)
    }

    @Test func aClearRightAfterAnOwnEditIsLookedAtAgainWhenTheWindowEnds() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        let first = checkEmpty(&watch, at: 40)
        #expect(first == .recheck(at: at(ClearWatch.ownEditWindowMs)))
        #expect(watch.holds, "nothing of the run is typed into the field meanwhile")
        let again = checkEmpty(&watch, at: ClearWatch.ownEditWindowMs)
        #expect(sentBase(again) == 12, "the clear is not lost")
        #expect(!watch.holds)
    }

    @Test func aFieldThatShowsTextAgainAtTheRecheckWasNoClear() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        let first = checkEmpty(&watch, at: 40)
        #expect(first == .recheck(at: at(ClearWatch.ownEditWindowMs)))
        let later = watch.check(
            state: live("hello world "), cursor: cursor(committedCount: 12), documentID: "doc-A",
            contextBefore: "hello world ", hasText: false, now: at(ClearWatch.ownEditWindowMs))
        #expect(later == .notCleared, "the context had lagged the keyboard's own edit")
        #expect(!watch.holds)
    }

    @Test func aKeyWhileAClearIsHeldTakesTheClearAsTheFieldWasBeforeTheKey() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        _ = checkEmpty(&watch, at: 40)
        #expect(watch.holds)
        let outcome = watch.resolveHeld(
            state: live("hello world "), cursor: cursor(committedCount: 12), documentID: "doc-A", contextBefore: "",
            hasText: false)
        #expect(sentBase(outcome) == 12, "the key must not hide the host's Send")
        #expect(!watch.holds)
    }

    @Test func aKeyWhileAHeldFieldShowsTextAgainTakesNothing() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        _ = checkEmpty(&watch, at: 40)
        let outcome = watch.resolveHeld(
            state: live("hello world "), cursor: cursor(committedCount: 12), documentID: "doc-A",
            contextBefore: "hello world ", hasText: true)
        #expect(outcome == .notCleared)
        #expect(!watch.holds)
    }

    @Test func aKeyWithNothingHeldTakesNothing() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        let outcome = watch.resolveHeld(
            state: live("hello world "), cursor: cursor(committedCount: 12), documentID: "doc-A", contextBefore: "",
            hasText: false)
        #expect(outcome == .notCleared, "no clear was held: the field is looked at by the usual checks")
    }

    @Test func anEmptyFieldWithoutTheRunsTextIsRecheckedButHoldsNothingBack() {
        var watch = ClearWatch()
        watch.ownEdit(at: at(0))
        let outcome = watch.check(
            state: live(""), cursor: cursor(committedCount: 0), documentID: "doc-A", contextBefore: "",
            hasText: false, now: at(40))
        #expect(outcome == .recheck(at: at(ClearWatch.ownEditWindowMs)))
        #expect(!watch.holds)
    }
}

/// The keyboard as `KeyboardController` drives it: the typewriter types the host's text on 33 ms ticks (each one
/// an own edit), and the field is checked for a clear before each plan and when it changes.
private struct TickRig {
    var reveal = TypewriterReveal()
    var watch = ClearWatch()
    var field = ""
    var cursor: AppliedCursor?
    var ms = 0.0
    var recheckAt: Date?

    /// One tick (or host update): look for a clear first; type nothing while one awaits its recheck.
    mutating func tick(_ state: HostState, elapsedMs: Double = 33) {
        ms += elapsedMs
        if let due = recheckAt, at(ms) >= due { recheckAt = nil }
        guard look(state) else { return }
        let plan = reveal.plan(
            state: state, cursor: cursor, contextBefore: field, documentID: "doc-A", animated: true, elapsedMs: elapsedMs)
        for op in plan.ops {
            switch op {
            case .deleteBackward(let count): field.removeLast(min(count, field.count))
            case .insert(let text): field += text
            }
        }
        if !plan.ops.isEmpty { watch.ownEdit(at: at(ms)) }
        cursor = plan.cursor
    }

    /// Whether the field may be typed into now.
    mutating func look(_ state: HostState) -> Bool {
        switch watch.check(state: state, cursor: cursor, documentID: "doc-A", contextBefore: field, hasText: !field.isEmpty, now: at(ms)) {
        case .notCleared: return true
        case .recheck(let due):
            recheckAt = due
            return !watch.holds
        case .cleared(let sent):
            if let sent { cursor = sent }
            return true
        }
    }

    /// The user presses a key: a held clear is resolved first, then the key lands in the field.
    mutating func userKey(_ text: String, _ state: HostState) {
        if case .cleared(let sent) = watch.resolveHeld(
            state: state, cursor: cursor, documentID: "doc-A", contextBefore: field, hasText: !field.isEmpty) {
            recheckAt = nil
            if let sent { cursor = sent }
        }
        field += text
        watch.ownEdit(at: at(ms))
    }

    mutating func drain(_ state: HostState, ticks: Int = 120) {
        for _ in 0..<ticks { tick(state) }
    }
}

@Suite struct ClearWatchFlowTests {
    @Test func aHostClearDuringTheTypewriterIsASentBoundaryOnceTheWindowEnds() {
        var rig = TickRig()
        rig.drain(live("hello world "))
        #expect(rig.field == "hello world ")

        // The next phrase is being typed when the host's Send button empties the field, 10 ms after a tick.
        rig.tick(live("hello world how are you "))
        #expect(rig.field.hasPrefix("hello world h"))
        let typed = rig.field.count
        rig.ms += 10
        rig.field = ""
        _ = rig.look(live("hello world how are you "))
        rig.drain(live("hello world how are you "))
        #expect(rig.cursor?.sentBase == typed, "the clear was believed after the window")
        #expect(rig.field == String("hello world how are you ".dropFirst(typed)), "only what was not sent goes in")

        let base = typed
        let after = HostRevision(
            n: 1, start: base, raw: String("hello world how are you ".dropFirst(base)), text: "How are you? ")
        rig.drain(live("hello world how are you ", revision: after))
        #expect(rig.field == "How are you? ", "later revisions apply to the text after the send")
        rig.drain(live("hello world how are you ", revision: after, phase: .idle))
        #expect(rig.cursor?.finalApplied == true)
    }

    @Test func aReturnThenTheHostsClearIsASentBoundaryAtOnce() {
        var rig = TickRig()
        rig.drain(live("hello world "))
        rig.watch.ownEdit(at: at(rig.ms)) // the Return removed nothing, but a tick had just typed
        rig.watch.returnTyped(at: at(rig.ms + 5))
        rig.ms += 10
        rig.field = ""
        let typeable = rig.look(live("hello world "))
        #expect(typeable)
        #expect(rig.cursor?.sentBase == 12)
        rig.drain(live("hello world see you "))
        #expect(rig.field == "see you ")
    }

    @Test(arguments: [30.0, 100.0, 200.0])
    func aKeyBeforeTheRecheckStillRecordsTheHostsSend(afterMs: Double) {
        var rig = TickRig()
        rig.drain(live("hello world "))
        let phrase = live("hello world how are you ")
        rig.tick(phrase)
        let typed = rig.field.count
        #expect(typed > 12)
        rig.ms += afterMs
        rig.field = "" // the host's Send, the field empties within the own-edit window
        let typeable = rig.look(phrase)
        #expect(!typeable, "the clear is held back")
        rig.ms += 5
        rig.userKey("O", phrase)
        #expect(rig.cursor?.sentBase == typed, "the boundary is recorded before the key")
        #expect(rig.cursor?.sentCount == 1)
        rig.drain(phrase)
        #expect(rig.field.hasPrefix("O"), "the key stays")
        #expect(rig.field == "O" + String("hello world how are you ".dropFirst(typed)), "only what was not sent goes in")
    }

    @Test func aHostClearWhileTheFinalStateIsStillTypedIsASentBoundary() {
        var rig = TickRig()
        let final = live("hello world how are you ", phase: .idle)
        rig.tick(final)
        #expect(rig.cursor?.finalApplied != true, "the typewriter has not finished the final state")
        let typed = rig.field.count
        #expect(typed > 0 && typed < 24)
        rig.ms += ClearWatch.ownEditWindowMs + 100
        rig.field = ""
        _ = rig.look(final)
        rig.drain(final)
        #expect(rig.cursor?.sentBase == typed)
        #expect(rig.field == String("hello world how are you ".dropFirst(typed)), "only what was not sent goes in")
        #expect(rig.cursor?.finalApplied == true)
    }
}
