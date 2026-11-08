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

/// One step against `field`, applying its ops (not animated unless asked).
@discardableResult
private func tick(_ shadow: inout RunShadow, _ field: inout Field, _ snap: LiveDictationSnapshot,
                  animated: Bool = false, elapsedMs: Double = 0, reported: String? = nil, selection: Bool = false) -> RunShadow.Step {
    let step = shadow.step(snapshot: snap, contextBefore: field.before, reportedBefore: reported ?? field.before,
                           hasSelection: selection, capitalization: .none, elapsedMs: elapsedMs, animated: animated)
    field.apply(step.ops)
    return step
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

    @Test func aWordFlipInTheMiddleOfTheRunTouchesOnlyThatWord() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "I think their going home."), head(1, "then we eat")]))
        let step = tick(&shadow, &field, snapshot(2, [final(0, "I think they're going home."), head(1, "then we eat")]))
        #expect(field.text == "I think they're going home. then we eat")
        #expect(step.rewrote && step.deletedChars == 5 && step.insertedChars == 7)
        #expect(field.after.isEmpty)
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

    @Test func emojiAndUTF16MovesLandOnTheRightWord() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "😀 Hallo wrld 👨‍👩‍👧 tschüss"), head(1, "bis bald")]))
        let step = tick(&shadow, &field, snapshot(2, [final(0, "😀 Hallo world 👨‍👩‍👧 tschüss"), head(1, "bis bald")]))
        #expect(field.text == "😀 Hallo world 👨‍👩‍👧 tschüss bis bald")
        #expect(step.deletedChars == 4 && step.insertedChars == 5)
    }

    @Test func frozenSentencesAreNotEditedAgainAndTheHeadKeepsAppendingAtTheCursor() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "their going home."), head(1, "then")]))
        let froze = shadow.freeze(.keystroke)
        #expect(froze)
        // The user types a word of their own; the cursor is at the end of the field.
        field.before += " X"
        tick(&shadow, &field, snapshot(2, [final(0, "They're going home.", cleaned: true), head(1, "then we eat")]))
        #expect(field.text == "their going home. then X we eat")
        #expect(shadow.frozenSegments == 2)
    }

    @Test func aClosedFrozenSentenceIsNeverTypedAgainButNewSentencesFollow() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [final(0, "first sentence.")]))
        shadow.freeze(.cursor)
        field.before = "first sentence. Z"
        tick(&shadow, &field, snapshot(2, [final(0, "First sentence!", cleaned: true), final(1, "second one.")]))
        #expect(field.text == "first sentence. Z second one.")
    }

    @Test func aHalfTypedWordContinuesWithoutASeparator() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "Hello wor")]))
        shadow.freeze(.keystroke)
        tick(&shadow, &field, snapshot(2, [head(0, "Hello world and")]))
        #expect(field.text == "Hello world and")
    }

    @Test func aHeadThatChangedUnderTheFrozenPartAppendsOnlyTheNewWords() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "we met their yesterday")]))
        shadow.freeze(.keystroke)
        field.before += "!"
        tick(&shadow, &field, snapshot(2, [head(0, "we met there yesterday and talked")]))
        #expect(field.text == "we met their yesterday! and talked")
    }

    @Test func aContextThatDoesNotEchoTheEditWaitsThenCountsAsDrift() {
        var shadow = RunShadow(runID: "r"), field = Field(before: "")
        tick(&shadow, &field, snapshot(1, [head(0, "hello")]))
        // The field still reports the old context: wait, do not type over it.
        let waiting = tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), elapsedMs: 100, reported: "")
        #expect(waiting.waiting && waiting.ops.isEmpty && field.text == "hello")
        // It never catches up: the user moved. Typing goes on at the cursor, frozen text stays.
        let drift = tick(&shadow, &field, snapshot(2, [head(0, "hello world")]), elapsedMs: 300, reported: "somewhere else")
        #expect(drift.froze == .drift)
        #expect(field.text == "hello world")
        #expect(shadow.frozenSegments == 1)
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

@Suite struct LiveDictationRunTests {
    @Test func buildsTheTargetFromFinalsCleanedSentencesAndTheHead() {
        var run = LiveDictationRun(runID: "r")
        run.setHead("hello wor")
        run.addFinal(key: 10, text: "hello world.")
        run.setHead("and then")
        #expect(run.snapshot.segments == [.init(id: 0, text: "hello world.", final: true), .init(id: 1, text: "and then", final: false)])
        let changed = run.setCleaned(key: 10, text: "Hello, world.")
        #expect(changed)
        #expect(run.snapshot.segments[0] == .init(id: 0, text: "Hello, world.", cleaned: true, final: true))
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
        run.addFinal(key: 4, text: "one.")
        run.addFinal(key: 5, text: "two.")
        run.addFinal(key: 6, text: "three.")
        run.setCleaned(key: 4, text: "One!")
        #expect(run.text(before: 6) == "One! two." && run.text(before: 4) == "" && run.text(before: 99) == "")
    }

    @Test func aDuplicateKeyAndEmptyTextAreIgnored() {
        var run = LiveDictationRun(runID: "r")
        run.addFinal(key: 0, text: "one.")
        run.addFinal(key: 0, text: "again")
        run.addFinal(key: 1, text: "   ")
        #expect(run.finalCount == 1)
    }

    @Test func finishingKeepsTheHeadAsAFinalSentenceAndStopsTakingWords() {
        var run = LiveDictationRun(runID: "r")
        run.setHead("half said")
        run.finish()
        #expect(run.complete && run.snapshot.segments == [.init(id: 0, text: "half said", final: true)])
        let v = run.version
        run.setHead("late")
        #expect(run.version == v)
    }
}
