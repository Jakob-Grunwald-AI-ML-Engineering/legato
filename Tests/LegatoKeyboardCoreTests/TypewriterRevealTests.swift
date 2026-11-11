import Testing
@testable import LegatoKeyboardCore

/// The keyboard's loop in miniature: a field that applies the plans, fed host states and ticks.
private struct Rig {
    var reveal = TypewriterReveal()
    var caret = 0
    var field = "" { didSet { caret = field.utf16.count } }
    var cursor: AppliedCursor?
    var documentID: String? = "doc-A"
    var animated = true
    var finalSeenWhileIncomplete = false
    var history: [[ProxyOp]] = []

    /// One planning pass, as `applyHost` makes it. `context` overrides what the field reports (a stale read).
    @discardableResult
    mutating func feed(_ state: HostState, elapsedMs: Double = 0, context: String? = nil) -> ProxyPlan {
        let plan = reveal.plan(
            state: state, cursor: cursor, contextBefore: context ?? String(decoding: field.utf16.prefix(caret), as: UTF16.self), documentID: documentID,
            animated: animated, elapsedMs: elapsedMs, contextAfter: String(decoding: field.utf16.dropFirst(caret), as: UTF16.self))
        history.append(plan.ops)
        let applied = applyProxyOps(plan.ops, to: field, cursor: caret)
        field = applied.text
        caret = applied.cursor
        if plan.cursor?.finalApplied == true, field != state.committed + state.volatile { finalSeenWhileIncomplete = true }
        // The field queue lands the proposed edit at once here (this field confirms synchronously).
        cursor = reveal.pendingEdit.flatMap { reveal.landed($0.id) } ?? plan.cursor
        return plan
    }

    /// Ticks at ~30 Hz until nothing is left to reveal; returns how many it took.
    @discardableResult
    mutating func drain(_ state: HostState, tickMs: Double = 33, limit: Int = 400) -> Int {
        var ticks = 0
        while reveal.needsTicks, ticks < limit {
            feed(state, elapsedMs: tickMs)
            ticks += 1
        }
        return ticks
    }
}

@Suite struct TypewriterRevealTests {
    private let sentence = "Hello world, this is a typewriter test."

    @Test(arguments: [false, true])
    func aNewFinalRunDuringUnconfirmedTypingIsNotDropped(tentative: Bool) {
        var rig = Rig()
        let old = hostState(runID: "old", committed: tentative ? "" : "abc", volatile: tentative ? "abc" : "")
        rig.feed(old)
        rig.feed(old, elapsedMs: 33)
        #expect(rig.field == "a")
        let next = hostState(runID: "next", phase: .idle, committed: "Z")
        rig.feed(next)
        rig.drain(next)
        #expect(rig.field == (tentative ? "Z" : "a Z"))
        #expect(rig.cursor?.runID == "next" && rig.cursor?.finalApplied == true)
    }

    // MARK: draining

    @Test func aNewRunTypesNothingUntilTheFirstTick() {
        var rig = Rig()
        let plan = rig.feed(hostState(committed: sentence))
        #expect(plan.ops.isEmpty)
        #expect(rig.reveal.needsTicks)
        #expect(rig.field == "")
    }

    @Test func theFieldGrowsByPrefixAndEndsWithExactlyTheText() {
        var rig = Rig()
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        var lengths: [Int] = []
        while rig.reveal.needsTicks, lengths.count < 400 {
            rig.feed(state, elapsedMs: 33)
            #expect(sentence.hasPrefix(rig.field))
            lengths.append(rig.field.count)
        }
        #expect(rig.field == sentence)
        #expect(lengths.count > 3) // it was spread over several ticks
        #expect(lengths == lengths.sorted())
        #expect(!rig.reveal.needsTicks)
    }

    @Test func finalIsReportedOnlyOnceEverythingIsInTheField() {
        var rig = Rig()
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        rig.feed(state, elapsedMs: 33)
        #expect(rig.cursor?.finalApplied != true)
        rig.drain(state)
        #expect(rig.cursor?.finalApplied == true)
        #expect(!rig.finalSeenWhileIncomplete)
    }

    @Test func aTickAfterTheEndChangesNothing() {
        var rig = Rig()
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        rig.drain(state)
        let plan = rig.feed(state, elapsedMs: 33)
        #expect(plan.ops.isEmpty)
        #expect(rig.field == sentence)
    }

    @Test func theInsertPathTypesAFreshFinalStateTheSameWay() {
        var rig = Rig()
        let state = hostState(runID: "insert-1", phase: .idle, committed: sentence, insertAt: t0)
        rig.feed(state)
        #expect(rig.field == "")
        rig.drain(state)
        #expect(rig.field == sentence)
        #expect(rig.cursor?.finalApplied == true)
    }

    @Test func graphemeClustersAreNeverSplit() {
        var rig = Rig()
        let text = "Hi 👨‍👩‍👧 there é 🇩🇪!"
        let state = hostState(phase: .idle, committed: text)
        rig.feed(state)
        while rig.reveal.needsTicks {
            rig.feed(state, elapsedMs: 5)
            #expect(text.hasPrefix(rig.field))
        }
        #expect(rig.field == text)
    }

    // MARK: following the host while draining

    @Test func streamedGrowthAndPromotionEndWithoutDuplicatesOrGaps() {
        var rig = Rig()
        rig.feed(hostState(volatile: "Hello wor"))
        rig.feed(hostState(volatile: "Hello wor"), elapsedMs: 33)
        rig.feed(hostState(volatile: "Hello worl"), elapsedMs: 33)
        rig.feed(hostState(committed: "Hello world", volatile: " ag"), elapsedMs: 33)
        rig.feed(hostState(committed: "Hello world", volatile: " again"), elapsedMs: 33)
        let final = hostState(phase: .idle, committed: "Hello world again")
        rig.feed(final, elapsedMs: 33)
        rig.drain(final)
        #expect(rig.field == "Hello world again")
        #expect(rig.cursor?.finalApplied == true)
        #expect(rig.cursor?.committedCount == "Hello world again".count)
    }

    @Test func aSlowFeedKeepsTheLagBounded() {
        // The text arrives faster than a tick reveals it; the drain still ends exactly on the last state.
        var rig = Rig()
        var spoken = ""
        for word in ["one ", "two ", "three ", "four ", "five ", "six "] {
            spoken += word
            rig.feed(hostState(volatile: spoken), elapsedMs: 33)
            #expect(spoken.hasPrefix(rig.field))
        }
        let final = hostState(phase: .idle, committed: spoken)
        rig.feed(final, elapsedMs: 33)
        rig.drain(final)
        #expect(rig.field == spoken)
    }

    // MARK: revisions

    @Test func aRevisionOfWhatIsTypedAlreadyAnimatesOnlyTheChanges() {
        var rig = Rig()
        let first = hostState(volatile: "Hello wor")
        rig.feed(first)
        rig.drain(first)
        #expect(rig.field == "Hello wor")
        let plan = rig.feed(hostState(volatile: "Hello were now"))
        // Only the differing characters change: nothing typed already is deleted and typed again.
        let deleted = plan.ops.reduce(0) { if case .deleteBackward(let n) = $1 { $0 + n } else { $0 } }
        #expect(deleted <= 2)
        #expect(rig.reveal.needsTicks)
        rig.drain(hostState(volatile: "Hello were now"))
        #expect(rig.field == "Hello were now")
    }

    @Test func aRevisionOfTheUnrevealedTailKeepsAnimating() {
        var rig = Rig()
        rig.feed(hostState(volatile: "Hello wonderful world"))
        rig.feed(hostState(volatile: "Hello wonderful world"), elapsedMs: 33)
        let before = rig.field
        #expect(!before.isEmpty && before.count < 21)
        let revised = hostState(volatile: "Hello wonderful day")
        rig.feed(revised)
        #expect(rig.field == before) // nothing snapped
        #expect(rig.reveal.needsTicks)
        rig.drain(revised)
        #expect(rig.field == "Hello wonderful day")
    }

    @Test func aRevisionThatShortensTheTextBelowWhatIsTypedAnimates() {
        var rig = Rig()
        let first = hostState(volatile: "Hello wor")
        rig.feed(first)
        rig.drain(first)
        rig.feed(hostState(volatile: "Hello"))
        #expect(rig.reveal.needsTicks)
        rig.drain(hostState(volatile: "Hello"))
        #expect(rig.field == "Hello")
        #expect(!rig.reveal.needsTicks)
    }

    @Test func aRevisionMidDrainThenFinalEndsWithTheFinalText() {
        var rig = Rig()
        rig.feed(hostState(volatile: "Hello wonderful world"))
        for _ in 0..<3 { rig.feed(hostState(volatile: "Hello wonderful world"), elapsedMs: 33) }
        rig.feed(hostState(volatile: "Hallo wonderful world"), elapsedMs: 33) // rewrites typed text
        rig.drain(hostState(volatile: "Hallo wonderful world"))
        #expect(rig.field == "Hallo wonderful world")
        let final = hostState(phase: .idle, committed: "Hallo wonderful world!")
        rig.feed(final, elapsedMs: 33)
        rig.drain(final)
        #expect(rig.field == "Hallo wonderful world!")
        #expect(rig.cursor?.finalApplied == true)
    }

    // MARK: snapping

    @Test func withoutAnimationTheFirstPlanTypesEverything() {
        var rig = Rig()
        rig.animated = false
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        rig.drain(state)
        #expect(rig.field == sentence)
        #expect(rig.cursor?.finalApplied == true)
        #expect(!rig.reveal.needsTicks)
    }

    @Test func turningAnimationOffMidDrainFlushesTheRest() {
        var rig = Rig()
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        rig.feed(state, elapsedMs: 33)
        #expect(rig.field.count < sentence.count)
        rig.animated = false
        rig.feed(state)
        rig.drain(state)
        #expect(rig.field == sentence)
        #expect(rig.cursor?.finalApplied == true)
    }

    // MARK: runs and the cursor

    @Test func aNewRunStartsFromNothingAndClearsTheLastRunsTentativeText() {
        var rig = Rig()
        rig.field = "Dear Bob, old"
        rig.cursor = cursor(runID: "run-0", volatile: "old")
        rig.feed(hostState(runID: "run-1", volatile: "new text"))
        #expect(rig.reveal.needsTicks)
        rig.drain(hostState(runID: "run-1", volatile: "new text"))
        #expect(rig.field == "Dear Bob, new text")
    }

    @Test func aRestartedKeyboardContinuesFromWhatTheCursorSays() {
        var rig = Rig()
        rig.field = "Hello wor"
        rig.cursor = cursor(committedCount: 5, volatile: " wor")
        let state = hostState(committed: "Hello", volatile: " world")
        let plan = rig.feed(state)
        #expect(plan.ops.isEmpty) // nothing deleted and retyped
        rig.drain(state)
        #expect(rig.field == "Hello world")
    }

    @Test func noFieldStopsTheTicksAndKeepsTheCursor() {
        var rig = Rig()
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        let kept = rig.cursor
        rig.documentID = nil
        let plan = rig.feed(state, elapsedMs: 33)
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor == kept)
        #expect(!rig.reveal.needsTicks)
    }

    @Test func aRunBoundToAnotherFieldIsLeftAlone() {
        var rig = Rig()
        let state = hostState(phase: .idle, committed: sentence)
        rig.feed(state)
        rig.documentID = "doc-B"
        let plan = rig.feed(state, elapsedMs: 33)
        #expect(plan.ops.isEmpty)
        #expect(!rig.reveal.needsTicks)
    }

    @Test func aStateForTheAppsOwnScreenIsNotDrained() {
        var rig = Rig()
        let plan = rig.feed(hostState(target: .app, committed: sentence), elapsedMs: 33)
        #expect(plan.ops.isEmpty)
        #expect(!rig.reveal.needsTicks)
    }

    // MARK: a context that has not caught up

    @Test func aContextThatLacksTheTentativeTextMakesTheTickWait() {
        // Right after an insert the field may still report the old context; planning against it would
        // type the tentative text a second time.
        var rig = Rig()
        let state = hostState(volatile: sentence)
        rig.feed(state)
        rig.feed(state, elapsedMs: 33)
        let typed = rig.field
        #expect(!typed.isEmpty)
        let plan = rig.feed(state, elapsedMs: 33, context: "")
        #expect(plan.ops.isEmpty)
        #expect(rig.field == typed)
        #expect(rig.reveal.needsTicks)
        rig.drain(state)
        #expect(rig.field == sentence)
    }

    @Test func withoutAnimationAStaleContextStillWaits() {
        var rig = Rig()
        rig.animated = false
        let state = hostState(volatile: "Hello")
        rig.field = "Hel" // a restarted keyboard resumes an earlier partial
        rig.cursor = cursor(volatile: "Hel")
        let plan = rig.feed(state, context: "")
        #expect(plan.ops.isEmpty)
        #expect(rig.reveal.needsTicks)
        rig.feed(state)
        rig.drain(state)
        #expect(rig.field == "Hello")
    }

    @Test func hostUpdatesWhileWaitingDoNotUseUpTheWait() {
        var rig = Rig()
        let state = hostState(volatile: sentence)
        rig.feed(state)
        rig.feed(state, elapsedMs: 33)
        for _ in 0..<50 { #expect(rig.feed(state, context: "").ops.isEmpty) } // no time passes
        #expect(rig.reveal.needsTicks)
    }
}

@Suite struct TypewriterCharacterPacingTests {
    @Test func insertingUnicodeEmitsOneWholeGraphemePerMutation() {
        var rig = Rig()
        let target = hostState(phase: .idle, committed: "A 👨‍👩‍👧 é 🇩🇪!")
        rig.feed(target)
        rig.drain(target)
        for ops in rig.history {
            #expect(ops.count <= 1)
            for op in ops {
                if case .insert(let text) = op { #expect(text.count == 1) }
            }
        }
        #expect(rig.field == target.committed)
        #expect(rig.cursor?.finalApplied == true)
    }
}
