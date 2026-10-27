import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputSuggestionStateTests {
    private let t = Date(timeIntervalSince1970: 9_000)
    private func at(_ s: TimeInterval) -> Date { t.addingTimeInterval(s) }

    private func move(_ s: inout SuggestionState, _ before: String, _ after: String, selected: Bool = false, _ time: TimeInterval = 0) -> WordRowContent {
        s.cursorMoved(contextBefore: before, contextAfter: after, hasSelection: selected, at: at(time))
    }

    // MARK: B

    @Test func startsEmpty() {
        #expect(SuggestionState().content == .empty)
    }

    @Test func aKeystrokeInsideAWordShowsCompletions() {
        var s = SuggestionState()
        #expect(s.keystroke(contextBefore: "Say hel", at: at(0)) == .completions(prefix: "hel"))
    }

    @Test func aKeystrokeThatLeavesASpaceShowsPredictionsAfterThePreviousWord() {
        var s = SuggestionState()
        #expect(s.keystroke(contextBefore: "Say hello ", at: at(0)) == .predictions(previous: "hello"))
    }

    @Test func atTheStartOfAFieldOrAfterANewlinePredictionsHaveNoPreviousWord() {
        var s = SuggestionState()
        #expect(s.keystroke(contextBefore: "", at: at(0)) == .predictions(previous: nil))
        #expect(s.keystroke(contextBefore: "Done.\n", at: at(1)) == .predictions(previous: nil))
    }

    @Test func afterPunctuationWithoutASpaceTheRowIsEmpty() {
        var s = SuggestionState()
        #expect(s.keystroke(contextBefore: "Hello,", at: at(0)) == .empty)
    }

    // MARK: A

    @Test func anExternalCursorMoveOntoAWordShowsAlternatives() {
        var s = SuggestionState()
        let c = move(&s, "Das ist ein Hau", "s hier")
        #expect(c == .alternatives(word: "Haus", span: WordSpan(before: 3, after: 1), requestID: 1))
    }

    @Test func anExternalCursorMoveIntoSpaceShowsPredictions() {
        var s = SuggestionState()
        #expect(move(&s, "Das ist ", " ein Haus") == .predictions(previous: "ist"))
    }

    @Test func anExternalMoveAfterPunctuationShowsNothing() {
        var s = SuggestionState()
        #expect(move(&s, "Hallo,", "") == .empty)
    }

    @Test func aSelectionShowsNothing() {
        var s = SuggestionState()
        #expect(move(&s, "Das ", "Haus", selected: true) == .empty)
    }

    @Test func eachNewTapGetsANewRequestID() {
        var s = SuggestionState()
        _ = move(&s, "a b", " c", 0)
        let second = move(&s, "a b c", "", 1)
        #expect(second == .alternatives(word: "c", span: WordSpan(before: 1, after: 0), requestID: 2))
    }

    @Test func theSameMoveReportedTwiceKeepsItsRequestID() {
        // selectionDidChange and textDidChange share one handler and often both fire.
        var s = SuggestionState()
        let first = move(&s, "Das Hau", "s", 0)
        let second = move(&s, "Das Hau", "s", 0.01)
        #expect(first == second)
    }

    // MARK: newest intent wins

    @Test func aKeystrokeAfterAlternativesSwitchesToCompletions() {
        var s = SuggestionState()
        _ = move(&s, "Das Hau", "s", 0)
        #expect(s.keystroke(contextBefore: "Das Hauz", at: at(2)) == .completions(prefix: "Hauz"))
    }

    @Test func anExternalMoveAfterCompletionsSwitchesToAlternatives() {
        var s = SuggestionState()
        _ = s.keystroke(contextBefore: "one two thr", at: at(0))
        let c = move(&s, "one tw", "o thr", 2)
        guard case .alternatives(let word, _, _) = c else { Issue.record("expected alternatives, got \(c)"); return }
        #expect(word == "two")
    }

    // MARK: own edits

    @Test func aCursorMoveThatMatchesTheKeyboardsOwnEditIsSuppressed() {
        var s = SuggestionState()
        _ = s.keystroke(contextBefore: "Say hel", at: at(0))
        s.willApplyOwnEdit(expectedContextBefore: "Say hello ", at: at(0.1))
        let c = move(&s, "Say hello ", "", 0.2)
        #expect(c == .completions(prefix: "hel"))
    }

    @Test func theSameOwnEditMayBeReportedSeveralTimesInsideTheWindow() {
        var s = SuggestionState()
        s.willApplyOwnEdit(expectedContextBefore: "ab ", at: at(0))
        _ = move(&s, "ab ", "", 0.1)
        let before = s.content
        #expect(move(&s, "ab ", "", 0.3) == before)
    }

    @Test func aMatchingMoveAfterTheSettleWindowIsExternal() {
        var s = SuggestionState()
        s.willApplyOwnEdit(expectedContextBefore: "ab cd", at: at(0))
        let c = move(&s, "ab cd", "", 2)
        guard case .alternatives = c else { Issue.record("expected alternatives, got \(c)"); return }
    }

    @Test func aDifferentContextInsideTheWindowIsAnIntermediateStateOfTheOwnEditAndIsIgnored() {
        // A swap reaches the host in steps (move, deletes, insert); the reports between them are not the user.
        var s = SuggestionState()
        s.willApplyOwnEdit(expectedContextBefore: "ab cd", at: at(0))
        #expect(move(&s, "ab", " cd", 0.2) == .empty)
        #expect(move(&s, "ab cd", "", 0.3) == .empty, "the final echo must still count as the keyboard's own")
    }

    @Test func theSuppressionLapsesWithTheWindow() {
        var s = SuggestionState()
        s.willApplyOwnEdit(expectedContextBefore: "ab cd", at: at(0))
        _ = move(&s, "ab", " cd", 0.2)
        guard case .alternatives(let w, _, _) = move(&s, "ab", " cd", 1) else { Issue.record("expected alternatives"); return }
        #expect(w == "ab")
    }

    // MARK: status and runs

    @Test func aStatusTakesOverTheRow() {
        var s = SuggestionState()
        _ = s.keystroke(contextBefore: "he", at: at(0))
        #expect(s.status("Listening…") == .status("Listening…"))
    }

    @Test func aRunPausesCompletionsAndAlternatives() {
        var s = SuggestionState()
        _ = s.status("Listening…")
        s.runActive(true)
        #expect(s.keystroke(contextBefore: "he", at: at(0)) == .status("Listening…"))
        #expect(move(&s, "a b", " c", 1) == .status("Listening…"))
    }

    @Test func aRunWithoutStatusTextShowsAnEmptyRow() {
        var s = SuggestionState()
        _ = s.keystroke(contextBefore: "he", at: at(0))
        #expect(s.runActive(true) == .empty)
        #expect(s.keystroke(contextBefore: "hel", at: at(1)) == .empty)
    }

    @Test func whenTheRunEndsTheRowIsEmptyUntilTheNextIntent() {
        var s = SuggestionState()
        _ = s.status("Cleaning…")
        s.runActive(true)
        _ = s.status(nil)
        #expect(s.runActive(false) == .empty)
        #expect(s.keystroke(contextBefore: "Hi ", at: at(0)) == .predictions(previous: "Hi"))
    }

    @Test func clearingTheStatusWithoutARunReleasesTheRow() {
        var s = SuggestionState()
        _ = s.status("Hint")
        #expect(s.status(nil) == .empty)
    }

    @Test func aRunStartedThenStatusClearedStaysPaused() {
        var s = SuggestionState()
        s.runActive(true)
        _ = s.status("x")
        _ = s.status(nil)
        #expect(s.keystroke(contextBefore: "he", at: at(0)) == .empty)
    }
}
