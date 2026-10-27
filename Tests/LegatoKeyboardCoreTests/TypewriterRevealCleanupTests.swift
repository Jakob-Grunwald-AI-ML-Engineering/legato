import Testing
@testable import LegatoKeyboardCore

/// The keyboard's loop in miniature (as in `TypewriterRevealTests`): a field that applies the plans.
private struct Rig {
    var reveal = TypewriterReveal()
    var field = ""
    var cursor: AppliedCursor?
    var inserts: [String] = []

    @discardableResult
    mutating func feed(_ state: HostState, elapsedMs: Double = 0, context: String? = nil) -> ProxyPlan {
        let plan = reveal.plan(
            state: state, cursor: cursor, contextBefore: context ?? field, documentID: "doc-A", animated: true,
            elapsedMs: elapsedMs)
        for op in plan.ops {
            switch op {
            case .deleteBackward(let count): field.removeLast(min(count, field.count))
            case .insert(let text):
                field += text
                inserts.append(text)
            }
        }
        cursor = plan.cursor
        return plan
    }

    mutating func drain(_ state: HostState, limit: Int = 400) {
        var ticks = 0
        while reveal.needsTicks, ticks < limit {
            feed(state, elapsedMs: 33)
            ticks += 1
        }
    }
}

private func state(
    phase: HostPhase, committed: String, volatile: String = "", delivery: HostDelivery?, finalText: String? = nil
) -> HostState {
    var host = hostState(phase: phase, committed: committed, volatile: volatile)
    host.delivery = delivery
    host.finalText = finalText
    return host
}

@Suite struct TypewriterRevealCleanupTests {
    private let raw = "um hello world this is the raw text "
    private let cleaned = "Hello, world. This is the cleaned text."

    // MARK: hold

    @Test func aHeldRunTypesNothingWhileListeningAndNeedsNoTicks() {
        var rig = Rig()
        rig.feed(state(phase: .listening, committed: raw, delivery: .hold))
        #expect(rig.field.isEmpty)
        #expect(!rig.reveal.needsTicks)
        rig.feed(state(phase: .finishing, committed: raw, delivery: .hold), elapsedMs: 33)
        #expect(rig.field.isEmpty)
    }

    @Test func aHeldRunInsertsTheCleanedTextOnceAndTicksDoNotInsertItAgain() {
        var rig = Rig()
        rig.feed(state(phase: .listening, committed: raw, delivery: .hold))
        let final = state(phase: .idle, committed: raw, delivery: .hold, finalText: cleaned)
        rig.feed(final)
        #expect(rig.field == cleaned)
        #expect(rig.cursor?.finalApplied == true)
        #expect(!rig.reveal.needsTicks)
        for _ in 0..<10 { rig.feed(final, elapsedMs: 33) }
        #expect(rig.field == cleaned)
        #expect(rig.inserts == [cleaned])
    }

    // MARK: replace

    @Test func aReplacedRunTypesTheRawTextThenSwapsInTheCleanedTextOnce() {
        var rig = Rig()
        let listening = state(phase: .listening, committed: raw, delivery: .replace)
        rig.feed(listening)
        rig.drain(listening)
        #expect(rig.field == raw)

        let final = state(phase: .idle, committed: raw, delivery: .replace, finalText: cleaned)
        rig.feed(final)
        rig.drain(final)
        #expect(rig.field == cleaned + " ")
        #expect(rig.cursor?.finalApplied == true)
        #expect(rig.cursor?.finalReplaced == true)
        for _ in 0..<5 { rig.feed(final, elapsedMs: 33) }
        #expect(rig.field == cleaned + " ")
    }

    @Test func aFinalStateThatArrivesMidRevealIsConfirmedOnlyAfterTheSwap() {
        var rig = Rig()
        let final = state(phase: .idle, committed: raw, delivery: .replace, finalText: cleaned)
        var confirmedEarly = false
        rig.feed(final)
        var ticks = 0
        while rig.reveal.needsTicks, ticks < 400 {
            rig.feed(final, elapsedMs: 33)
            if rig.cursor?.finalApplied == true, rig.field != cleaned + " " { confirmedEarly = true }
            ticks += 1
        }
        #expect(!confirmedEarly)
        #expect(rig.field == cleaned + " ")
        #expect(rig.cursor?.finalReplaced == true)
        #expect(ticks > 3) // the raw text was still typed out, not dropped in at once
    }

    @Test func theSwapWaitsForAContextThatStillLacksTheStreamedText() {
        var rig = Rig()
        let final = state(phase: .idle, committed: raw, delivery: .replace, finalText: cleaned)
        rig.feed(final)
        // Everything revealed, but the field reports the old context for a few ticks.
        while rig.reveal.needsTicks, rig.field != raw { rig.feed(final, elapsedMs: 33, context: "") }
        // One tick with a stale context: the swap does not happen on a guess.
        let held = rig.feed(final, elapsedMs: 33, context: "")
        #expect(held.ops.isEmpty)
        #expect(rig.reveal.needsTicks)
        #expect(rig.field == raw)
        rig.feed(final, elapsedMs: 33)
        #expect(rig.field == cleaned + " ")
        #expect(rig.cursor?.finalReplaced == true)
    }

    @Test func aFieldTheUserMovedOnFromIsLeftAloneAndNotConfirmed() {
        var rig = Rig()
        let final = state(phase: .idle, committed: raw, delivery: .replace, finalText: cleaned)
        rig.feed(final)
        while rig.reveal.needsTicks, rig.field != raw { rig.feed(final, elapsedMs: 33) }
        rig.field += "and then I typed"
        rig.drain(final)
        #expect(rig.field == raw + "and then I typed")
        #expect(rig.cursor?.finalReplaced == false)
        #expect(rig.cursor?.finalApplied == false)
        #expect(!rig.reveal.needsTicks)
    }

    // MARK: clipboard

    @Test func aClipboardRunKeepsTheStreamedTextAndConfirmsItAfterTheReveal() {
        var rig = Rig()
        let final = state(phase: .idle, committed: raw, delivery: .clipboard, finalText: cleaned)
        rig.feed(final)
        rig.drain(final)
        #expect(rig.field == raw)
        #expect(rig.cursor?.finalApplied == true)
        #expect(rig.cursor?.finalReplaced == nil)
    }

    // MARK: live

    private let liveRaw = "hello world how are you "
    private let liveRevision = HostRevision(start: 0, raw: "hello world ", text: "Hello world. ")
    private let liveFinal = "Hello world. how are you "

    private func live(phase: HostPhase = .listening, revisions: [HostRevision]? = nil) -> HostState {
        var host = state(phase: phase, committed: liveRaw, delivery: .live)
        host.revisions = revisions
        return host
    }

    @Test func aRevisionWaitsUntilTheRevealCoversItsRawSpan() {
        var rig = Rig()
        let host = live(revisions: [liveRevision])
        rig.feed(host)
        var ticks = 0
        while rig.reveal.needsTicks, ticks < 400 {
            rig.feed(host, elapsedMs: 33)
            ticks += 1
            if rig.field.count < liveRevision.raw.count {
                #expect(liveRaw.hasPrefix(rig.field), "no revision fires on a span that is still being typed")
                #expect(rig.cursor?.revisionsHandled == 0)
            }
        }
        #expect(rig.field == liveFinal)
        #expect(rig.cursor?.revisionsHandled == 1)
        #expect(rig.cursor?.revisionSkipped != true)
        #expect(ticks > 3)
    }

    @Test func aRevisionIsNotSkippedBecauseTheFieldHasNotCaughtUpWithTheReveal() {
        var rig = Rig()
        let host = live(revisions: [liveRevision])
        rig.feed(host)
        while rig.field.isEmpty, rig.reveal.needsTicks { rig.feed(host, elapsedMs: 33) }
        #expect(!rig.field.isEmpty && rig.field.count < liveRevision.raw.count)
        // The field still reports the context from before the last inserts: the revision would find
        // nothing to replace there, and a skip is for good, so it waits instead.
        var stale = 0
        while rig.cursor?.revisionsHandled == 0, stale < 3 {
            rig.feed(host, elapsedMs: 33, context: "")
            stale += 1
        }
        #expect(rig.cursor?.revisionSkipped != true)
        #expect(rig.cursor?.revisionsHandled == 0)
        #expect(rig.reveal.needsTicks)
        // The field settles: the revision applies.
        rig.drain(host)
        #expect(rig.field == liveFinal)
        #expect(rig.cursor?.revisionsHandled == 1)
        #expect(rig.cursor?.revisionSkipped != true)
    }

    @Test func aRevisionIsSkippedForGoodWhenTheUserTypedAroundTheRevealedText() {
        var rig = Rig()
        let host = live(revisions: [liveRevision])
        rig.feed(host)
        while rig.field.isEmpty, rig.reveal.needsTicks { rig.feed(host, elapsedMs: 33) }
        rig.field += "!" // the user types into the dictation
        rig.drain(host)
        #expect(rig.cursor?.revisionsHandled == 1)
        #expect(rig.cursor?.revisionSkipped == true)
        #expect(!rig.field.contains("Hello"))
        #expect(!rig.reveal.needsTicks)
    }

    @Test func theFinalStateIsConfirmedOnlyOnceEveryRevisionLanded() {
        var rig = Rig()
        let host = live(phase: .idle, revisions: [liveRevision])
        var early = false
        rig.feed(host)
        var ticks = 0
        while rig.reveal.needsTicks, ticks < 400 {
            rig.feed(host, elapsedMs: 33)
            if rig.cursor?.finalApplied == true, rig.field != liveFinal { early = true }
            ticks += 1
        }
        #expect(!early)
        #expect(rig.field == liveFinal)
        #expect(rig.cursor?.finalApplied == true)
    }
}
