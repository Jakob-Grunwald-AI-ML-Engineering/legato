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

    // MARK: live

    private let liveRaw = "hello world how are you "

    @Test func aLiveRunsFinalStateIsConfirmedOnlyOnceAllOfItIsRevealed() {
        var rig = Rig()
        let host = state(phase: .idle, committed: liveRaw, delivery: .live)
        var early = false
        rig.feed(host)
        var ticks = 0
        while rig.reveal.needsTicks, ticks < 400 {
            rig.feed(host, elapsedMs: 33)
            if rig.cursor?.finalApplied == true, rig.field != liveRaw { early = true }
            ticks += 1
        }
        #expect(!early)
        #expect(rig.field == liveRaw)
        #expect(rig.cursor?.finalApplied == true)
    }
}
