import Testing
@testable import LegatoKeyboardCore

/// A text field: what is before and after the cursor, and the proxy ops applied to it.
private struct Field {
    var before: String
    var after = ""
    mutating func apply(_ ops: [ShadowOp]) {
        let result = ShadowEditPlanner.simulate(ops: ops, shadow: before + after, cursor: before.utf16.count)
        let cursor = result.cursor
        let all = Array(result.text.utf16)
        before = String(decoding: all[..<cursor], as: UTF16.self)
        after = String(decoding: all[cursor...], as: UTF16.self)
    }
    var text: String { before + after }
}

private func snapshot(_ version: Int, _ segments: [LiveSegment], complete: Bool = false) -> LiveDictationSnapshot {
    .init(runID: "r", version: version, segments: segments, complete: complete)
}
private func final(_ id: Int, _ text: String, cleaned: Bool = false) -> LiveSegment { .init(id: id, text: text, cleaned: cleaned, final: true) }
private func head(_ id: Int, _ text: String) -> LiveSegment { .init(id: id, text: text, final: false) }

/// One step against `field`, applying its ops (not animated unless asked). `drain`: the field confirms at once, so
/// keep stepping (a flip's typewriter pace apart) until the edit queue is empty; the steps are merged into one. `settle`: after a freeze the shadow
/// waits for the field's report to hold still; keep stepping (100 ms apart) until it types or stops waiting.
@discardableResult
private func tick(_ shadow: inout RunShadow, _ field: inout Field, _ snap: LiveDictationSnapshot,
                  animated: Bool = false, elapsedMs: Double = 0, reported: String? = nil, reportedAfter: String? = nil,
                  selection: Bool = false, settle: Bool = false, drain: Bool = true) -> RunShadow.Step {
    func one(_ elapsedMs: Double) -> RunShadow.Step {
        let step = shadow.step(snapshot: snap, contextBefore: field.before, reportedBefore: reported ?? field.before,
                               reportedAfter: reportedAfter ?? field.after, hasSelection: selection, capitalization: .none,
                               elapsedMs: elapsedMs, animated: animated, followingCharacter: field.after.first)
        field.apply(step.ops)
        return step
    }
    var merged = one(elapsedMs)
    var guardCount = 0
    while guardCount < 200, (settle && merged.waiting) || (drain && shadow.isBusy && !merged.waiting) {
        guardCount += 1
        let next = one(settle && merged.waiting ? 100 : RunShadow.flipCharMs)
        merged.ops += next.ops; merged.insertedChars += next.insertedChars; merged.deletedChars += next.deletedChars
        merged.rewrote = merged.rewrote || next.rewrote; merged.froze = merged.froze ?? next.froze
        merged.coalesced += next.coalesced; merged.startDetail = merged.startDetail ?? next.startDetail
        merged.applied = merged.applied || next.applied; merged.version = next.version ?? merged.version
        merged.waiting = next.waiting; merged.needsTicks = next.needsTicks
    }
    return merged
}

@Suite struct RunShadowTests {
    @Test func appendsGrowTheFieldAndSeparateFromTheAnchor() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "Hi.")
        tick(&shadow, &field, snapshot(1, [head(0, "hello wor")]))
        #expect(field.text == "Hi. hello wor")
        let step = tick(&shadow, &field, snapshot(2, [head(0, "hello world and")]))
        #expect(field.text == "Hi. hello world and")
        #expect(step.ops == [.insert("ld and")] && !step.rewrote && step.applied)
    }

    @Test func animatedAppendsRevealOverTicksAndNeverPastTheTarget() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        let snap = snapshot(1, [head(0, "the quick brown fox jumps")])
        var steps = 0
        while true {
            let step = tick(&shadow, &field, snap, animated: true, elapsedMs: 33)
            steps += 1
            if step.applied { break }
            #expect(step.needsTicks && steps < 100)
        }
        #expect(field.text == "the quick brown fox jumps" && steps > 1)
    }

    @Test func aWordFlipNearTheEndIsRetypedFromItsFirstChangeWithoutMoves() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "I think their going home."), head(1, "then we eat")]))
        let step = tick(&shadow, &field, snapshot(2, [final(0, "I think they're going home."), head(1, "then we eat")]))
        #expect(field.text == "I think they're going home. then we eat")
        // Everything from the first change ("i" of "their") is erased back from the end and typed again.
        let kept = "I think the".count
        #expect(step.rewrote && step.deletedChars == "I think their going home. then we eat".count - kept
                && step.insertedChars == field.text.count - kept)
        #expect(!step.ops.contains { if case .move = $0 { true } else { false } } && field.after.isEmpty)
    }

    @Test func aFlipFurtherBackThanTheRetypeWindowIsLeftForTheCleanedTake() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "I think their going home after the long walk."), head(1, "then we")]))
        let step = tick(&shadow, &field, snapshot(2, [final(0, "I think they're going home after the long walk."), head(1, "then we eat")]))
        #expect(field.text == "I think their going home after the long walk. then we eat", "The head still grows")
        #expect(!step.ops.contains { if case .move = $0 { true } else { false } } && step.deletedChars == 0)
        tick(&shadow, &field, snapshot(3, [final(0, "I think they're going home after the long walk.", cleaned: true),
                                           final(1, "Then we eat.", cleaned: true)], complete: true))
        #expect(field.text == "I think they're going home after the long walk. Then we eat.")
    }

    @Test func cleanupReplacesAnEarlierSentenceWhileTheHeadGrows() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "um so we shipped it yesterday"), head(1, "and then")]))
        // The cleaned sentence lands and the head has grown meanwhile.
        let step = tick(&shadow, &field, snapshot(2, [final(0, "So we shipped it yesterday.", cleaned: true), head(1, "and then we waited")]))
        #expect(field.text == "So we shipped it yesterday. and then we waited")
        #expect(step.rewrote)
        // And later the head is final and cleaned too.
        tick(&shadow, &field, snapshot(3, [final(0, "So we shipped it yesterday.", cleaned: true), final(1, "And then we waited.", cleaned: true)], complete: true))
        #expect(field.text == "So we shipped it yesterday. And then we waited.")
    }

    @Test func textAfterTheCursorStaysWhereItIs() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "Dear Sam,", after: " Best, Jo")
        tick(&shadow, &field, snapshot(1, [final(0, "thanks for the the file")]))
        tick(&shadow, &field, snapshot(2, [final(0, "Thanks for the file.", cleaned: true)]))
        #expect(field.text == "Dear Sam, Thanks for the file. Best, Jo")
        #expect(field.before == "Dear Sam, Thanks for the file.")
    }

    @Test func emojiAndUTF16FlipsAreRetypedByCharacter() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "😀 Hallo wrld 👨‍👩‍👧 tschüss"), head(1, "bis bald")]))
        let step = tick(&shadow, &field, snapshot(2, [final(0, "😀 Hallo world 👨‍👩‍👧 tschüss"), head(1, "bis bald")]))
        #expect(field.text == "😀 Hallo world 👨‍👩‍👧 tschüss bis bald")
        let kept = "😀 Hallo w".count
        #expect(step.deletedChars == "😀 Hallo wrld 👨‍👩‍👧 tschüss bis bald".count - kept && step.insertedChars == field.text.count - kept)
    }

    @Test func frozenSentencesAreNotEditedAgainAndTheHeadKeepsAppendingAtTheCursor() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "their going home."), head(1, "then")]))
        let froze = shadow.freeze(.keystroke)
        #expect(froze)
        // The user types a word of their own; the cursor is at the end of the field.
        field.before += " X"
        tick(&shadow, &field, snapshot(2, [final(0, "They're going home.", cleaned: true), head(1, "then we eat")]), settle: true)
        #expect(field.text == "their going home. then X we eat")
        #expect(shadow.frozenSegments == 2)
    }

    @Test func aKeyWhileAWordIsHalfRevealedFinishesTheWordFirst() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        let snap = snapshot(1, [head(0, "enough soil for the beds")])
        // The typewriter has revealed "enough so".
        while field.text != "enough so" { tick(&shadow, &field, snap, animated: true, elapsedMs: 1) }
        let op = shadow.finishWord(beforeKey: "X", reportedBefore: field.before, reportedAfter: field.after)
        #expect(op == .insert("il "))
        field.apply(op.map { [$0] } ?? [])
        shadow.freeze(.keystroke)
        field.before += "XY "
        tick(&shadow, &field, snap, settle: true)
        #expect(field.text == "enough soil XY for the beds")
        // Nothing is cut off at a word end, and a key that is no letter gets no space.
        var other = RunShadow(runID: "r"), second = Field(before: "")
        tick(&other, &second, snapshot(1, [head(0, "hello")]))
        #expect(other.finishWord(beforeKey: "X", reportedBefore: second.before, reportedAfter: "") == nil)
        var third = RunShadow(runID: "r"), field3 = Field(before: "")
        while field3.text != "hel" { tick(&third, &field3, snapshot(1, [head(0, "hello, you")]), animated: true, elapsedMs: 1) }
        #expect(third.finishWord(beforeKey: ".", reportedBefore: field3.before, reportedAfter: "") == .insert("lo,"))
    }

    @Test func aClosedFrozenSentenceIsNeverTypedAgainButNewSentencesFollow() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "first sentence.")]))
        shadow.freeze(.cursor)
        field.before = "first sentence. Z"
        tick(&shadow, &field, snapshot(2, [final(0, "First sentence!", cleaned: true), final(1, "second one.")]), settle: true)
        #expect(field.text == "first sentence. Z second one.")
    }

    @Test func aWordCutOffByTheFreezeIsTypedWholeAtTheNewCursorNotLost() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "Hello wor")]))
        shadow.freeze(.keystroke)
        field.before += "!"
        tick(&shadow, &field, snapshot(2, [head(0, "Hello world and")]), settle: true)
        #expect(field.text == "Hello wor! world and")
        // The same when the sentence changed under the frozen part meanwhile.
        var other = RunShadow(runID: "r"), second = Field(before: "")
        tick(&other, &second, snapshot(1, [head(0, "we met their yest")]))
        other.freeze(.cursor)
        tick(&other, &second, snapshot(2, [head(0, "we met there yesterday and talked")]), settle: true)
        #expect(second.text == "we met their yest yesterday and talked")
        // And when cleanup changed the cut word's case.
        var third = RunShadow(runID: "r"), field3 = Field(before: "")
        tick(&third, &field3, snapshot(1, [head(0, "and then w")]))
        third.freeze(.cursor)
        tick(&third, &field3, snapshot(2, [final(0, "And Then We Can Go.", cleaned: true)], complete: true), settle: true)
        #expect(field3.text == "and then w We Can Go.")
    }

    @Test func aTapIntoTheTypedTextFreezesAsACursorMoveAndTheRestFollowsAtTheNewCursor() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "The sheet is ready")]))
        // The user taps after "The": the field now reports only the text before that cursor.
        field = Field(before: "The", after: " sheet is ready")
        let frozen = tick(&shadow, &field, snapshot(2, [head(0, "The sheet is ready and then")]), elapsedMs: 1600, reported: "The")
        #expect(frozen.froze == .cursor)
        tick(&shadow, &field, snapshot(2, [head(0, "The sheet is ready and then")]), settle: true)
        #expect(field.text == "The and then sheet is ready")
        #expect(field.before == "The and then", "Nothing of the sentence is lost and the cursor ends after what was typed")
        _ = shadow
    }

    @Test func aReportThatMatchesNothingTypedIsDriftNotACursorMove() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "hello world")]))
        let frozen = tick(&shadow, &field, snapshot(1, [head(0, "hello world")]), elapsedMs: 1600, reported: "something else")
        #expect(frozen.froze == .drift)
    }

    @Test func aRunInTheMiddleOfTextGetsOneSpaceBeforeWhatFollowsAndKeepsTypingInFrontOfIt() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "Start here. ", after: "End here.")
        tick(&shadow, &field, snapshot(1, [head(0, "Bring the")]))
        #expect(field.text == "Start here. Bring the End here." && field.before == "Start here. Bring the")
        tick(&shadow, &field, snapshot(2, [final(0, "Bring the laptop.")]))
        #expect(field.text == "Start here. Bring the laptop. End here.", "One space, not one per step")
        tick(&shadow, &field, snapshot(3, [final(0, "Bring the laptop."), head(1, "and chargers")]))
        #expect(field.text == "Start here. Bring the laptop. and chargers End here.")
    }

    @Test func noSpaceIsAddedBeforeAWhitespaceOrClosingMarkOrAtTheEndOfTheField() {
        for after in [" End", ".", ")", "\nNext", ""] {
            var shadow = RunShadow(runID: "r"), field = Field(before: "Start. ", after: after)
            tick(&shadow, &field, snapshot(1, [final(0, "Hello there.")]))
            #expect(field.text == "Start. Hello there." + after, "after: \(after.debugDescription)")
        }
    }

    @Test func aHeadThatChangedUnderTheFrozenPartAppendsOnlyTheNewWords() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "we met their yesterday")]))
        shadow.freeze(.keystroke)
        field.before += "!"
        tick(&shadow, &field, snapshot(2, [head(0, "we met there yesterday and talked")]), settle: true)
        #expect(field.text == "we met their yesterday! and talked")
    }

    @Test func aContextThatDoesNotEchoTheEditWaitsThenCountsAsDrift() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "hello")]))
        // The field still reports the old context: wait, do not type over it.
        let waiting = tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), elapsedMs: 100, reported: "")
        #expect(waiting.waiting && waiting.ops.isEmpty && field.text == "hello")
        // It never catches up: the user moved. Typing goes on at the cursor, frozen text stays.
        let drift = tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), elapsedMs: 700, reported: "somewhere else")
        #expect(drift.froze == .drift && drift.driftDetail?.contains("wsOnly=0") == true)
        tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), reported: "somewhere else", settle: true)
        #expect(field.text == "hello world")
        #expect(shadow.frozenSegments == 1)
    }

    @Test func editsGoOutOneAtATimeAndEachWaitsForTheFieldToConfirmIt() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "I think their going home."), head(1, "then we eat")]))
        let snap = snapshot(2, [final(0, "I think they're going home."), head(1, "then we eat and sleep")])
        let stale = field
        let first = tick(&shadow, &field, snap, drain: false)
        #expect(first.rewrote && first.ops.count == 1 && shadow.isBusy)
        // The host still reports the field as it was: nothing more goes out, and it is no drift yet.
        let waiting = tick(&shadow, &field, snap, elapsedMs: 200, reported: stale.before, reportedAfter: stale.after, drain: false)
        #expect(waiting.waiting && waiting.ops.isEmpty && waiting.froze == nil && waiting.waitStarted)
        // Once the report confirms, the rest follows one op per step.
        var sent = 1
        while shadow.isBusy, sent < 40 {
            let next = tick(&shadow, &field, snap, elapsedMs: RunShadow.flipCharMs, drain: false)
            #expect(next.ops.count == 1)
            sent += 1
        }
        #expect(sent >= 4 && field.text == "I think they're going home. then we eat and sleep" && field.after.isEmpty)
        // A report that never confirms an op freezes after the limit, and the rest of the queue never goes out.
        let flip = snapshot(3, [final(0, "I think they're going home."), head(1, "then we ate and sleep")])
        let before = field
        let next = tick(&shadow, &field, flip, drain: false)
        #expect(next.ops.count == 1 && shadow.isBusy)
        let sentOne = field
        let stuck = tick(&shadow, &field, flip, elapsedMs: 900, reported: before.before, reportedAfter: before.after, drain: false)
        #expect(stuck.froze == .drift && stuck.confirmTimedOut && !shadow.isBusy && field.text == sentOne.text)
    }

    @Test func snapshotsThatArriveWhileTheQueueIsBusyAreCoalescedToTheNewest() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "we met their yesterday."), head(1, "and")]))
        let first = tick(&shadow, &field, snapshot(2, [final(0, "we met there yesterday."), head(1, "and")]), drain: false)
        #expect(first.ops.count == 1 && shadow.isBusy)
        // Two more snapshots arrive while the flip goes out: v3 is dropped for v4 and its diff never runs.
        var coalesced = 0
        for snap in [snapshot(3, [final(0, "we met they're yesterday."), head(1, "and")]),
                     snapshot(4, [final(0, "we met there yesterday."), head(1, "and talked")])] {
            let step = tick(&shadow, &field, snap, drain: false)
            coalesced += step.coalesced
            #expect(!field.text.contains("they're"))
        }
        let v4 = snapshot(4, [final(0, "we met there yesterday."), head(1, "and talked")])
        let last = tick(&shadow, &field, v4)
        #expect(coalesced + last.coalesced == 1)
        tick(&shadow, &field, v4)
        #expect(field.text == "we met there yesterday. and talked" && !field.text.contains("they're"))
    }

    @Test func aFlushSendsTheRestOfTheQueueAndTheNewestTargetAtOnce() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "their going home."), head(1, "then")]))
        tick(&shadow, &field, snapshot(2, [final(0, "They're going home."), head(1, "then")]), drain: false)
        #expect(shadow.isBusy)
        let step = shadow.step(snapshot: snapshot(3, [final(0, "They're going home."), head(1, "then we eat")]),
                               contextBefore: field.before, reportedBefore: field.before, reportedAfter: field.after,
                               hasSelection: false, capitalization: .none, elapsedMs: 0, animated: false, flush: true)
        field.apply(step.ops)
        #expect(field.text == "They're going home. then we eat" && field.after.isEmpty && !shadow.isBusy && step.applied)
    }

    @Test func confirmationReadsBothSidesOfTheCursor() {
        #expect(RunShadow.confirms(expectedBefore: "Hi. we met", expectedAfter: " there", reportedBefore: "we met", reportedAfter: " there and"),
                "A trimmed report before the cursor, text that follows the region after it")
        #expect(!RunShadow.confirms(expectedBefore: "Hi. we met", expectedAfter: " there", reportedBefore: "Hi. we met", reportedAfter: " their"))
        #expect(!RunShadow.confirms(expectedBefore: "go", expectedAfter: " go", reportedBefore: "go go", reportedAfter: ""),
                "The cursor has not moved back yet")
        #expect(RunShadow.confirms(expectedBefore: "Hi. we met", expectedAfter: " there", reportedBefore: "Hi. we met", reportedAfter: ""),
                "A host that reports nothing after the cursor")
        #expect(RunShadow.confirms(expectedBefore: "Hi. we met", expectedAfter: "", reportedBefore: "Hi. we met", reportedAfter: " Best"))
        #expect(!RunShadow.confirms(expectedBefore: "Hi. we met", expectedAfter: "", reportedBefore: "Hi. we", reportedAfter: " met"))
    }

    @Test func afterAFreezeTheRunWaitsForTheReportToHoldStillAndSeedsFromIt() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "first.")]))
        shadow.freeze(.keystroke)
        // The report is still catching up with the user's text: no separator is judged against it yet.
        field.before = "first. A"
        let early = tick(&shadow, &field, snapshot(2, [final(0, "first."), head(1, "second")]), elapsedMs: 100, reported: "first.")
        #expect(early.waiting && early.ops.isEmpty)
        let still = tick(&shadow, &field, snapshot(2, [final(0, "first."), head(1, "second")]), elapsedMs: 100, reported: "first. A")
        #expect(still.waiting && still.ops.isEmpty)
        let typed = tick(&shadow, &field, snapshot(2, [final(0, "first."), head(1, "second")]), elapsedMs: 200, reported: "first. A")
        #expect(typed.ops == [.insert(" second")] && field.text == "first. A second")
    }

    @Test func aRunThatSettlesFirstDoesNotJudgeTheSeparatorAgainstAReportThatIsStillCatchingUp() {
        var shadow = RunShadow(runID: "r", settlesFirst: true), field = Field(before: "Start here. ")
        let snap = snapshot(1, [head(0, "So I wanted")])
        // Right after the tap the host still reports the text before the cursor without its trailing space.
        let stale = tick(&shadow, &field, snap, elapsedMs: 100, reported: "Start here.")
        #expect(stale.waiting && stale.ops.isEmpty)
        let caughtUp = tick(&shadow, &field, snap, elapsedMs: 100, reported: "Start here. ")
        #expect(caughtUp.waiting && caughtUp.ops.isEmpty)
        let typed = tick(&shadow, &field, snap, elapsedMs: 200, reported: "Start here. ")
        #expect(typed.ops == [.insert("So I wanted")] && field.text == "Start here. So I wanted")
    }

    @Test func aMatchingReportedContextAfterALagIsNotDrift() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "Start.")
        tick(&shadow, &field, snapshot(1, [head(0, "hello")]))
        tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), elapsedMs: 100, reported: "Start.")
        let step = tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), elapsedMs: 100)
        #expect(step.froze == nil && !step.waiting && step.applied)
    }

    @Test func aSelectionFreezesAndTypesNothing() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "hello")]))
        let step = tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), selection: true)
        #expect(step.froze == .selection && step.ops.isEmpty && field.text == "hello")
    }

    @Test func anEmptyTargetNeverErasesTypedText() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "hello")]))
        tick(&shadow, &field, snapshot(2, []))
        #expect(field.text == "hello")
    }

    @Test func aNewAnchorIsTakenFromTheCursorWhileNothingIsTyped() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "One.")
        tick(&shadow, &field, snapshot(1, []))
        field.before = "One. Two."
        tick(&shadow, &field, snapshot(2, [head(0, "three")]))
        #expect(field.text == "One. Two. three")
    }

    @Test func capitalizationFollowsTheTextBeforeTheCursor() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "Done.")
        let snap = snapshot(1, [head(0, "next up")])
        let step = shadow.step(snapshot: snap, contextBefore: field.before, reportedBefore: field.before, hasSelection: false,
                               capitalization: .sentences, elapsedMs: 0, animated: false)
        field.apply(step.ops)
        #expect(field.text == "Done. Next up")
    }
}

@Suite struct LiveUnitShadowTests {
    @Test func theCleanedTakeReplacesItsPauseFragmentsAndDropsAnAllFillerUnit() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "Um."), final(1, "so, uh, the plan is ready now."), final(2, "Yeah.")]))
        #expect(field.text == "Um. so, uh, the plan is ready now. Yeah.")
        tick(&shadow, &field, snapshot(2, [
            .init(id: 0, text: "So the plan is ready now.", cleaned: true, final: true, unit: 0, raw: "Um."),
            .init(id: 1, text: "", cleaned: true, final: true, unit: 0, raw: "so, uh, the plan is ready now."),
            .init(id: 2, text: "", cleaned: true, final: true),
        ], complete: true))
        #expect(field.text == "So the plan is ready now." && field.after.isEmpty)
    }

    @Test func aFreezeAfterTheCleanedTakeNeverTypesItsFragmentsRawWordsAgain() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "Um."), final(1, "so, uh, the plan is ready now.")]))
        let cleaned = snapshot(2, [
            .init(id: 0, text: "The plan is ready now.", cleaned: true, final: true, unit: 0, raw: "Um."),
            .init(id: 1, text: "", cleaned: true, final: true, unit: 0, raw: "so, uh, the plan is ready now."),
        ], complete: true)
        tick(&shadow, &field, cleaned)
        #expect(field.text == "The plan is ready now.")
        // The field is cleared (or edited) after the take: the run freezes and must not type anything again.
        field = Field(before: "")
        let frozen = tick(&shadow, &field, cleaned, elapsedMs: 900)
        #expect(frozen.froze != nil)
        tick(&shadow, &field, cleaned, settle: true)
        #expect(field.text == "", "Nothing of the old run comes back")
    }

    @Test func aTakeOfNothingButFillerIsErasedWhenItsCleanupDropsIt() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "Hi.")
        tick(&shadow, &field, snapshot(1, [final(0, "Um.")]))
        #expect(field.text == "Hi. Um.")
        // A target without words that is no cleaned take never erases anything.
        tick(&shadow, &field, snapshot(2, [head(0, "")]))
        #expect(field.text == "Hi. Um.")
        tick(&shadow, &field, snapshot(3, [final(0, "", cleaned: true)], complete: true))
        #expect(field.text == "Hi.")
    }

    @Test func aUnitWithAFrozenPartFallsBackToItsRawWords() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "Um.")]))
        shadow.freeze(.keystroke)
        field.before += " X"
        tick(&shadow, &field, snapshot(2, [final(0, "Um."), final(1, "the plan is ready.")]), settle: true)
        #expect(field.text == "Um. X the plan is ready.")
        tick(&shadow, &field, snapshot(3, [
            .init(id: 0, text: "The plan is ready.", cleaned: true, final: true, unit: 0, raw: "Um."),
            .init(id: 1, text: "", cleaned: true, final: true, unit: 0, raw: "the plan is ready."),
        ], complete: true))
        #expect(field.text == "Um. X the plan is ready.", "Nothing of the unit is lost or typed twice")
    }

    @Test func aFlipTypesItsCharactersOneAtATimeAtTheTypewriterPace() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "I think their going home."), head(1, "then")]))
        let snap = snapshot(2, [final(0, "I think they're going home."), head(1, "then")])
        // 10 ms ticks: an insert that follows an insert goes out only `flipCharMs` after it.
        var ops: [ShadowOp] = [], now = 0.0, lastInsert: Double?, previousWasInsert = false
        var step = tick(&shadow, &field, snap, drain: false)
        while true {
            for op in step.ops {
                if case .insert(let text) = op {
                    #expect(text.count == 1, "One character per op")
                    if previousWasInsert, let last = lastInsert { #expect(now - last >= RunShadow.flipCharMs) }
                    lastInsert = now; previousWasInsert = true
                } else { previousWasInsert = false }
                ops.append(op)
            }
            guard shadow.isBusy, now < 2000 else { break }
            now += 10
            step = tick(&shadow, &field, snap, elapsedMs: 10, drain: false)
        }
        #expect(field.text == "I think they're going home. then" && field.after.isEmpty)
        let kept = "I think the".count
        #expect(ops.first == .deleteBackward("I think their going home. then".count - kept))
        #expect(ops.filter { if case .insert = $0 { true } else { false } }.count == field.text.count - kept)
        #expect(!ops.contains { if case .move = $0 { true } else { false } }, "The cursor never leaves the end")
        // The complete take inserts its retyped tail whole.
        let done = tick(&shadow, &field, snapshot(3, [final(0, "I think they're going home.", cleaned: true), final(1, "Then.", cleaned: true)], complete: true))
        #expect(field.text == "I think they're going home. Then." && done.ops.contains(.insert("Then.")))
    }
}

@Suite struct LiveDictationRunTests {
    @Test func buildsTheTargetFromFinalsCleanedSentencesAndTheHead() {
        var run = LiveDictationRun(runID: "r")
        run.setHead("hello wor")
        run.addFinal(key: 10, text: "hello world.")
        run.setHead("and then")
        #expect(run.snapshot.segments == [.init(id: 0, text: "hello world.", final: true), .init(id: 1, text: "and then", final: false)])
        let v = run.version
        let changed = run.setCleaned(key: 10, text: "Hello, world.")
        #expect(!changed && run.version == v, "While the take runs the cleaned sentence is held back")
        #expect(run.snapshot.segments[0] == .init(id: 0, text: "hello world.", final: true))
        run.finish()
        #expect(run.snapshot.segments[0] == .init(id: 0, text: "Hello, world.", cleaned: true, final: true))
    }

    @Test func allCleanedSentencesLandInTheOneSnapshotThatEndsTheTake() {
        var run = LiveDictationRun(runID: "r")
        run.addFinal(key: 0, text: "this is the first one here.")
        run.addFinal(key: 1, text: "this is the second one here.")
        run.addFinal(key: 2, text: "this is the third one here.")
        run.setCleaned(key: 0, text: "One.")
        run.setCleaned(key: 2, text: "Three!")
        let open = run.version
        run.finish()
        #expect(run.version == open + 1)
        #expect(run.snapshot.segments.map(\.text) == ["One.", "this is the second one here.", "Three!"])
        #expect(run.snapshot.segments.map(\.cleaned) == [true, false, true])
    }

    @Test func aFinalTakesOverTheHeadWithTheSameId() {
        var run = LiveDictationRun(runID: "r")
        run.addFinal(key: 0, text: "one.")
        run.setHead("two")
        let headID = run.snapshot.segments.last?.id
        run.addFinal(key: 1, text: "two.")
        #expect(run.snapshot.segments.last?.id == headID)
        let allFinal = run.snapshot.segments.allSatisfy { $0.final }
        #expect(allFinal)
    }

    @Test func versionOnlyMovesWhenTheTargetChanges() {
        var run = LiveDictationRun(runID: "r")
        run.setHead("a")
        let v = run.version
        run.setHead("a")
        #expect(run.version == v)
        run.addFinal(key: 0, text: "a.")
        let w = run.version
        let same = run.setCleaned(key: 0, text: "a."), unknown = run.setCleaned(key: 9, text: "unknown")
        #expect(!same && !unknown)
        #expect(run.version == w)
    }

    @Test func theTextBeforeASentenceIsTheSentencesSoFar() {
        var run = LiveDictationRun(runID: "r")
        run.addFinal(key: 4, text: "this is the first one here.")
        run.addFinal(key: 5, text: "this is the second one here.")
        run.addFinal(key: 6, text: "this is the third one here.")
        run.setCleaned(key: 4, text: "One!")
        #expect(run.text(before: 6) == "One! this is the second one here." && run.text(before: 4) == "" && run.text(before: 99) == "")
    }

    @Test func pauseFragmentsGroupIntoOneUnitUntilASentenceEndsAndTheTakesEndFlushesTheRest() {
        var run = LiveDictationRun(runID: "r")
        #expect(run.addFinal(key: 0, text: "Um.") == nil, "Too short to end a unit")
        #expect(run.addFinal(key: 1, text: "so, uh, the plan") == nil)
        let unit = run.addFinal(key: 2, text: "is ready for the review.")
        #expect(unit == "Um. so, uh, the plan is ready for the review." && run.unitCount == 1 && run.unitSegments(key: 1) == 3)
        #expect(run.addFinal(key: 3, text: "Yeah.") == nil)
        let rest = run.flush()
        #expect(rest?.key == 3 && rest?.text == "Yeah." && run.flush() == nil)
        // A line break ends a unit however short; the word cap ends one without a sentence end.
        #expect(LiveDictationRun.endsUnit("new line\n") && !LiveDictationRun.endsUnit("one two three."))
        #expect(LiveDictationRun.endsUnit(Array(repeating: "word", count: LiveDictationRun.maxUnitWords).joined(separator: " ")))
    }

    @Test func aCleanedUnitOfSeveralSegmentsLandsOnItsFirstAndAnEmptyOneDropsItsWords() {
        var run = LiveDictationRun(runID: "r")
        run.addFinal(key: 0, text: "Um.")
        run.addFinal(key: 1, text: "so, uh, the plan is ready now.")
        run.addFinal(key: 2, text: "Yeah.")
        _ = run.flush()
        run.setCleaned(key: 1, text: "So the plan is ready now.")
        run.setCleaned(key: 2, text: "")
        #expect(run.text(before: 2) == "So the plan is ready now.")
        run.finish()
        #expect(run.snapshot.segments == [
            .init(id: 0, text: "So the plan is ready now.", cleaned: true, final: true, unit: 0, raw: "Um."),
            .init(id: 1, text: "", cleaned: true, final: true, unit: 0, raw: "so, uh, the plan is ready now."),
            .init(id: 2, text: "", cleaned: true, final: true),
        ])
    }

    @Test func aDuplicateKeyAndEmptyTextAreIgnored() {
        var run = LiveDictationRun(runID: "r")
        run.addFinal(key: 0, text: "one.")
        run.addFinal(key: 0, text: "again")
        run.addFinal(key: 1, text: "   ")
        #expect(run.finalCount == 1)
    }

    @Test func finishingLeavesTheHeadAsShownAndALateSegmentStillLandsInTheRun() {
        var run = LiveDictationRun(runID: "r")
        run.setHead("half said")
        run.finish()
        #expect(run.complete && run.snapshot.segments == [.init(id: 0, text: "half said", final: false)])
        let v = run.version
        run.setHead("late")
        #expect(run.version == v, "No new words after the end")
        // The segment of those words arrives late: it replaces the head in place and keeps the segment id.
        let sentence = run.addFinal(key: 3, text: "half said.")
        #expect(sentence == "half said." && run.snapshot.segments == [.init(id: 0, text: "half said.", final: true)] && run.complete)
        let late = run.setCleaned(key: 3, text: "Half said.")
        #expect(late)
    }

    @Test func aCutShortSegmentWaitsInTheHeadAndTheSentenceIsCleanedWhole() {
        var run = LiveDictationRun(runID: "r")
        run.setHead("one two three")
        let first = run.addFinal(key: 0, text: "one two three", closes: false)
        #expect(first == nil && run.finalCount == 0)
        run.setHead("four five")
        #expect(run.snapshot.segments == [.init(id: 0, text: "one two three four five", final: false)])
        let whole = run.addFinal(key: 1, text: "four five six.")
        #expect(whole == "one two three four five six." && run.finalCount == 1)
        #expect(run.snapshot.segments == [.init(id: 0, text: "one two three four five six.", final: true)], "The head keeps its id when the sentence closes")
        let cleaned = run.setCleaned(key: 1, text: "One two three, four five six.")
        #expect(!cleaned, "Held until the take ends")
        run.addFinal(key: 2, text: "next one.")
        #expect(run.text(before: 2) == "One two three, four five six.")
    }

}

@Suite struct SentenceStartCapitalTests {
    @Test func aLowercaseStartAfterASentenceEndOrNothingGetsACapital() {
        #expect(SentenceStart.capitalized("we should go.", after: "") == "We should go.")
        #expect(SentenceStart.capitalized("we should go.", after: "Okay.") == "We should go.")
        #expect(SentenceStart.capitalized("we should go.", after: "Really?! ") == "We should go.")
        #expect(SentenceStart.capitalized("we should go.", after: "He said \"stop.\"") == "We should go.")
        #expect(SentenceStart.capitalized("we should go.", after: "Done.)\n") == "We should go.")
        #expect(SentenceStart.capitalized("élan is back.", after: "") == "Élan is back.")
    }

    @Test func aStartInsideASentenceOrWithIntendedLowercaseStays() {
        #expect(SentenceStart.capitalized("and then we left.", after: "We came in,") == "and then we left.")
        #expect(SentenceStart.capitalized("and then we left.", after: "Hello") == "and then we left.")
        #expect(SentenceStart.capitalized("iPhone sales rose.", after: "Okay.") == "iPhone sales rose.")
        #expect(SentenceStart.capitalized("eBay is down.", after: "") == "eBay is down.")
        #expect(SentenceStart.capitalized("github.com/x is up.", after: "Okay.") == "github.com/x is up.")
        #expect(SentenceStart.capitalized("@sarah wrote back.", after: "Okay.") == "@sarah wrote back.")
        #expect(SentenceStart.capitalized("www.example.com works.", after: "Okay.") == "www.example.com works.")
        #expect(SentenceStart.capitalized("1 more thing.", after: "Okay.") == "1 more thing.")
        #expect(SentenceStart.capitalized("Already fine.", after: "Okay.") == "Already fine.")
    }
}

/// A web view's field: it reports only `window` characters before the cursor (and as many after it, or nothing), may
/// drop a move, and may be a page that puts its caret back where its last input event left it a moment later (a
/// controlled textarea that re-renders two steps after the input), after the report already showed the keyboard's
/// next op. A lagging field reports the cursor where it was before a move for a few reads after showing it. ASCII only.
private struct WebField {
    var text: [Character] = []
    var cursor = 0
    var window = 1000
    var reportsAfter = true
    var restoresCaret = false
    /// The moves (counted from 1) the field ignores.
    var dropsMoves: Set<Int> = []
    /// After a move: the first read shows it, the next `lagReads` reads show the cursor before it again.
    var lagReads = 0
    private var moves = 0
    private var lagFrom: Int?
    private var lagFresh = 0
    private var lagLeft = 0
    private var caretAfterInput: Int?
    private var rendersLeft = 0

    // Spelled out: older compilers make the memberwise initializer private because of the private state above.
    init(window: Int = 1000, reportsAfter: Bool = true, restoresCaret: Bool = false, dropsMoves: Set<Int> = [], lagReads: Int = 0) {
        self.window = window; self.reportsAfter = reportsAfter; self.restoresCaret = restoresCaret
        self.dropsMoves = dropsMoves; self.lagReads = lagReads
    }

    var full: String { String(text) }
    var before: String { String(text[..<cursor]) }
    /// What the field reports now (a lagging field may report an older cursor).
    mutating func report() -> (before: String, after: String) {
        var at = cursor
        if let from = lagFrom {
            if lagFresh > 0 { lagFresh -= 1 } else if lagLeft > 0 { lagLeft -= 1; at = from } else { lagFrom = nil }
        }
        return (String(text[..<at].suffix(window)), reportsAfter ? String(text[at...].prefix(window)) : "")
    }

    /// The page's render after an input event: the caret goes back where that event left it.
    mutating func render() {
        guard let caret = caretAfterInput else { return }
        rendersLeft -= 1
        if rendersLeft <= 0 { cursor = caret; caretAfterInput = nil }
    }
    mutating func apply(_ ops: [ShadowOp]) {
        for op in ops {
            switch op {
            case .move(let units):
                moves += 1
                if !dropsMoves.contains(moves) {
                    if lagReads > 0 { lagFrom = cursor; lagFresh = 1; lagLeft = lagReads }
                    cursor = max(0, min(text.count, cursor + units))
                }
            case .deleteBackward(let count):
                let n = min(count, cursor)
                text.removeSubrange((cursor - n)..<cursor); cursor -= n
                if restoresCaret { caretAfterInput = cursor; rendersLeft = 2 }
            case .insert(let string):
                text.insert(contentsOf: string, at: cursor); cursor += string.count
                if restoresCaret { caretAfterInput = cursor; rendersLeft = 2 }
            }
        }
    }
}

/// Steps `snap` against a web field, 30 ms apart, until it is applied or frozen: the report is read first (it
/// already shows the last op), then the page renders, then the step's ops land.
@discardableResult
private func drive(_ shadow: inout RunShadow, _ field: inout WebField, _ snap: LiveDictationSnapshot, limit: Int = 400) -> [RunShadow.Step] {
    var steps: [RunShadow.Step] = []
    for _ in 0..<limit {
        let report = field.report()
        let step = shadow.step(snapshot: snap, contextBefore: field.before, reportedBefore: report.before,
                               reportedAfter: report.after, hasSelection: false, capitalization: .none,
                               elapsedMs: RunShadow.flipCharMs, animated: false)
        field.render()
        field.apply(step.ops)
        steps.append(step)
        if step.froze != nil || (step.applied && !shadow.isBusy) { break }
    }
    return steps
}

@Suite struct WebFieldMoveTests {
    /// A long take (its cleanup's first change more than `cleanupRetypeChars` from the end): it lands with cursor moves.
    static let middle = (1...40).map { "Sentence number \($0) talks about step \($0) of the long checklist." }.joined(separator: " ")
    static let raw = "Lina we ship it today. " + middle + " Or do we wait for Lina ?"
    static let cleaned = "Lina, we ship it today. " + middle + " Or do we wait for Lina?"

    @Test func aShortWindowThatFitsTheOldPlaceTooDoesNotConfirmAMove() {
        // After the queue deleted the space before "?", it moves to after the first "Lina". A web view reports four
        // characters before the cursor and nothing after it: "Lina" is the end of both places.
        let known = "Lina we wait for Lina?"
        #expect(!RunShadow.confirms(expectedBefore: "Lina", expectedAfter: String(known.dropFirst(4)), reportedBefore: "Lina", reportedAfter: ""),
                "The move did not happen (the cursor is still before \"?\"), and the report cannot tell")
        #expect(!RunShadow.confirms(expectedBefore: "Lina", expectedAfter: String(known.dropFirst(4)), reportedBefore: "for Lina", reportedAfter: "?"),
                "The report shows the cursor before \"?\": a longer report does not fit the expected place as its suffix")
        #expect(RunShadow.confirms(expectedBefore: "Lina", expectedAfter: String(known.dropFirst(4)), reportedBefore: "Lina", reportedAfter: " we"),
                "The move happened: the text after the cursor pins it")
        #expect(RunShadow.confirms(expectedBefore: "Lina", expectedAfter: String(known.dropFirst(4)), reportedBefore: "Lina", reportedAfter: ""
                                   ) == false && RunShadow.positions(in: Array(known), reportedBefore: "Lina", reportedAfter: "") == [4, 21])
        // The same window in a longer text, with the anchor in front.
        #expect(RunShadow.confirms(expectedBefore: "Notes: I think", expectedAfter: " maybe so. What do you think?",
                                   reportedBefore: "Notes: I think", reportedAfter: ""))
        #expect(!RunShadow.confirms(expectedBefore: "Notes: I think", expectedAfter: " maybe so. What do you think?",
                                    reportedBefore: "think", reportedAfter: ""))
    }

    @Test func aDroppedMoveWithAnAmbiguousReportFreezesAndNothingLandsAtTheWrongPlace() {
        var shadow = RunShadow(runID: "r"), field = WebField(window: 4, reportsAfter: false, dropsMoves: [2])
        drive(&shadow, &field, snapshot(1, [final(0, Self.raw)]))
        #expect(field.full == Self.raw)
        let steps = drive(&shadow, &field, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(steps.contains { $0.froze != nil })
        // The move to after the first "Lina" is lost; the report ("Lina", nothing after it) fits there and where the
        // cursor still is. The queue stops: no comma lands at the end.
        #expect([Self.raw, Self.raw.replacingOccurrences(of: " ?", with: "?")].contains(field.full))
    }

    @Test func aMoveIsConfirmedByAShortWindowWhenItPinsThePlace() {
        var shadow = RunShadow(runID: "r"), field = WebField(window: 4, reportsAfter: true)
        drive(&shadow, &field, snapshot(1, [final(0, Self.raw)]))
        let steps = drive(&shadow, &field, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(field.full == Self.cleaned && steps.allSatisfy { $0.froze == nil })
        #expect(steps.flatMap(\.ops).contains { if case .move = $0 { true } else { false } }, "A long take still lands with moves")
    }

    @Test func aMoveTheFieldDropsGoesOutOnceMoreWhenTheReportPinsTheOldPlace() {
        var shadow = RunShadow(runID: "r"), field = WebField(dropsMoves: [2])
        drive(&shadow, &field, snapshot(1, [final(0, Self.raw)]))
        let steps = drive(&shadow, &field, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(field.full == Self.cleaned && field.cursor == field.text.count)
        #expect(steps.filter(\.moveResent).count == 1 && steps.allSatisfy { $0.froze == nil })
    }

    @Test func aMoveTheFieldDropsTwiceFreezesWithNothingTypedAtTheOldPlace() {
        var shadow = RunShadow(runID: "r"), field = WebField(dropsMoves: [2, 3])
        drive(&shadow, &field, snapshot(1, [final(0, Self.raw)]))
        let steps = drive(&shadow, &field, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(steps.contains { $0.froze != nil })
        #expect(field.full == Self.raw.replacingOccurrences(of: " ?", with: "?"))
        // The report pins the cursor (still before "?"): it goes back to the end of the run, not left mid-text.
        #expect(field.cursor == field.text.count && steps.last?.driftDetail?.contains("cleanup=parked") == true)
    }

    @Test func aLaggingReportThatShowsTheOldPlaceForAMomentIsNoCaretReset() {
        // Each move shows at once, then the report falls back to the old place for two reads, then catches up.
        var shadow = RunShadow(runID: "r"), field = WebField(lagReads: 2)
        drive(&shadow, &field, snapshot(1, [final(0, Self.raw)]))
        let steps = drive(&shadow, &field, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(field.full == Self.cleaned && field.cursor == field.text.count)
        #expect(steps.allSatisfy { $0.froze == nil } && !shadow.avoidsMoves)
    }

    @Test func aCleanedTakeOfSomeHundredWordsIsRetypedWithoutMovesInLargeInserts() {
        let middle = (1...20).map { "Sentence number \($0) talks about step \($0)." }.joined(separator: " ")
        let raw = "Lina we ship it today. " + middle + " Or do we wait for Lina ?"
        let cleaned = "Lina, we ship it today. " + middle + " Or do we wait for Lina?"
        var shadow = RunShadow(runID: "r"), field = WebField(window: 40, restoresCaret: true)
        drive(&shadow, &field, snapshot(1, [final(0, raw)]))
        let ops = drive(&shadow, &field, snapshot(2, [final(0, cleaned, cleaned: true)], complete: true)).flatMap(\.ops)
        #expect(field.full == cleaned && field.cursor == field.text.count)
        #expect(ops == [.deleteBackward(raw.count - 4), .insert(String(cleaned.dropFirst(4)))])
    }

    @Test func aPageThatPutsItsCaretBackAfterAMoveFreezesTheRunAndTurnsMovesOff() {
        // The report shows the move; a tick later the page has put its caret back where its last input left it.
        var shadow = RunShadow(runID: "r"), field = WebField(restoresCaret: true)
        drive(&shadow, &field, snapshot(1, [final(0, Self.raw)]))
        let steps = drive(&shadow, &field, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(steps.last?.froze == .caretReset && steps.last?.caretReset == true && shadow.avoidsMoves)
        #expect([Self.raw, Self.raw.replacingOccurrences(of: " ?", with: "?")].contains(field.full), "Nothing landed at the old place")
        #expect(field.cursor == field.text.count, "The cursor is put back at the end of the run")
        // The next run in that field (moves off for the session) leaves a take too long to retype as typed.
        var next = RunShadow(runID: "s", avoidsMoves: true), fresh = WebField(restoresCaret: true)
        drive(&next, &fresh, snapshot(1, [final(0, Self.raw)]))
        let left = drive(&next, &fresh, snapshot(2, [final(0, Self.cleaned, cleaned: true)], complete: true))
        #expect(fresh.full == Self.raw && fresh.cursor == fresh.text.count && left.flatMap(\.ops).isEmpty)
    }

    @Test func theCleanedShortTakeIsRetypedFromItsFirstChangeWithoutMoves() {
        // A split word, a filler and a stray space before "?": the cleanup changes an early word and the end.
        let raw = "I guess we coul d, uh, run the checks on the second branch. What would you say ?"
        let cleaned = "I guess we could run the checks on the second branch. What would you say?"
        var shadow = RunShadow(runID: "r"), field = WebField(window: 6, reportsAfter: false, restoresCaret: true)
        drive(&shadow, &field, snapshot(1, [final(0, "I guess we coul d, uh, run the checks on the second branch."), final(1, "What would you say ?")]))
        #expect(field.full == raw)
        let steps = drive(&shadow, &field, snapshot(2, [final(0, "I guess we could run the checks on the second branch.", cleaned: true),
                                                       final(1, "What would you say?", cleaned: true)], complete: true))
        let ops = steps.flatMap(\.ops)
        #expect(field.full == cleaned && field.cursor == field.text.count)
        #expect(ops == [.deleteBackward(raw.count - "I guess we coul".count), .insert(String(cleaned.dropFirst("I guess we coul".count)))])
        #expect(steps.reduce(0) { $0 + $1.deletedChars } == raw.count - "I guess we coul".count)
    }
}
