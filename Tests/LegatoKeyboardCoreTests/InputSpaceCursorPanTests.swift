import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputSpaceCursorPanTests {
    private func offset(steps: Int, before: String, after: String) -> Int {
        var session = SpaceCursorPan.Session(before: before, after: after)
        return session.move(by: steps)
    }

    @Test func ordinaryTapDoesNotConsumeSpace() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: true, x: 100)
        let consumesSpace = pan.finish()
        #expect(!consumesSpace)
    }

    @Test func holdConsumesReleaseEvenWithoutMoving() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: true, x: 100)
        let activated = pan.activate()
        #expect(activated)
        #expect(pan.isActive)
        let consumed = pan.finish()
        #expect(consumed)
        #expect(!pan.isActive)
        let repeatedEnd = pan.finish()
        #expect(!repeatedEnd)
    }

    @Test func slidingOntoSpaceCannotArm() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: false, x: 100)
        let activated = pan.activate()
        #expect(!activated)
        let steps = pan.move(to: 180)
        #expect(steps == 0)
        let consumed = pan.finish()
        #expect(!consumed)
    }

    @Test func movingBeforeHoldDoesNotJumpWhenItActivates() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: true, x: 100)
        let beforeHold = pan.move(to: 105)
        #expect(beforeHold == 0)
        let activated = pan.activate()
        #expect(activated)
        let belowThreshold = pan.move(to: 112)
        #expect(belowThreshold == 0)
        let atThreshold = pan.move(to: 113)
        #expect(atThreshold == 1)
    }

    @Test func movementPreservesResidualAndReversesImmediately() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: true, x: 100)
        let activated = pan.activate()
        #expect(activated)
        let twoSteps = pan.move(to: 119)
        #expect(twoSteps == 2)
        let residualStep = pan.move(to: 124)
        #expect(residualStep == 1)
        let reversed = pan.move(to: 116)
        #expect(reversed == -1)
        let returnToStart = pan.move(to: 100)
        #expect(returnToStart == -2)
    }

    @Test func leavingSpaceBeforeHoldDisarmsPermanently() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: true, x: 100)
        pan.cancelArming()
        let activatedAfterLeaving = pan.activate()
        #expect(!activatedAfterLeaving)
        let consumed = pan.finish()
        #expect(!consumed)
        pan.begin(onSpace: true, x: 100)
        let newTouchActivates = pan.activate()
        #expect(newTouchActivates)
    }

    @Test func intentionalPanBypassesRecentTypingEchoFence() {
        var suggestions = SuggestionState()
        let now = Date(timeIntervalSince1970: 100)
        _ = suggestions.keystroke(contextBefore: "hello ", at: now)
        suggestions.cursorPanBegan()
        let content = suggestions.cursorMoved(
            contextBefore: "hel", contextAfter: "lo ", hasSelection: false,
            at: now.addingTimeInterval(0.41))
        guard case .alternatives(let word, let span, _) = content else {
            Issue.record("Intentional pan must inspect the word immediately, not show old predictions")
            return
        }
        #expect(word == "hello")
        #expect(span.before == 3)
        #expect(span.after == 2)
    }

    @Test func offsetsClampToAvailableContext() {
        #expect(offset(steps: -9, before: "a👩🏽‍🚀", after: "") == -8)
        #expect(offset(steps: 9, before: "", after: "🇩🇪x") == 5)
    }

    @Test func missingDirectionalContextNeverGuessesUTF16Offsets() {
        #expect(offset(steps: -1, before: "", after: "👩🏽‍🚀") == 0)
        #expect(offset(steps: 1, before: "👩🏽‍🚀", after: "") == 0)
    }

    @Test func graphemeMovementDoesNotSplitEmojiOrCombiningMarks() {
        #expect(offset(steps: -1, before: "a👩🏽‍🚀", after: "") == -7)
        #expect(offset(steps: 2, before: "", after: "e\u{301}🇩🇪b") == 6)
        #expect(offset(steps: -2, before: "ab", after: "") == -2)
        #expect(offset(steps: 0, before: "ab", after: "cd") == 0)
    }

    @Test func touchCoordinateRoundingDoesNotLoseACompletedStep() {
        var pan = SpaceCursorPan()
        pan.begin(onSpace: true, x: 100)
        let activated = pan.activate()
        #expect(activated)
        let left = pan.move(to: 76.000000000001)
        #expect(left == -3)
        let right = pan.move(to: 100)
        #expect(right == 3)
    }

    @Test func panSnapshotAdvancesWithoutWaitingForProxyContext() {
        var session = SpaceCursorPan.Session(before: "ab👩🏽‍🚀", after: "cd")
        #expect(session.move(by: -1) == -7)
        #expect(session.move(by: -1) == -1)
        #expect(session.move(by: -1) == -1)
        #expect(session.move(by: -1) == 0)
    }

    @Test func panSnapshotReversesAcrossEmojiAndClampsAtKnownEdges() {
        var session = SpaceCursorPan.Session(before: "ab👩🏽‍🚀", after: "cd")
        #expect(session.move(by: -2) == -8)
        #expect(session.move(by: 1) == 1)
        #expect(session.move(by: 1) == 7)
        #expect(session.move(by: 9) == 2)
        #expect(session.move(by: 1) == 0)
        #expect(session.move(by: -1) == -1)
    }
}
