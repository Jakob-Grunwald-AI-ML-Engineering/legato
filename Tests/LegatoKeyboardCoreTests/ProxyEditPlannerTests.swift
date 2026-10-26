import Testing
@testable import LegatoKeyboardCore

@Suite struct ProxyEditPlannerTests {
    // MARK: volatile text

    @Test func firstVolatileIsInsertedAndBindsTheCurrentDocument() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(volatile: "hello"), cursor: nil, contextBefore: "", documentID: "doc-A")
        #expect(plan.ops == [.insert("hello")])
        #expect(plan.cursor == cursor(volatile: "hello"))
    }

    @Test func volatileGrowthInsertsOnlyTheNewSuffix() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(volatile: "hello world"), cursor: cursor(volatile: "hello wo"),
            contextBefore: "hello wo", documentID: "doc-A")
        #expect(plan.ops == [.insert("rld")])
        #expect(plan.cursor?.volatile == "hello world")
    }

    @Test func volatileRevisionDeletesOnlyTheDivergentTail() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(volatile: "hello word"), cursor: cursor(volatile: "hello world"),
            contextBefore: "hello world", documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(2), .insert("d")])
        #expect(plan.cursor?.volatile == "hello word")
    }

    @Test func unchangedStateProducesNoOps() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(volatile: "hello"), cursor: cursor(volatile: "hello"),
            contextBefore: "hello", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor == cursor(volatile: "hello"))
    }

    @Test func volatileShrinkingToNothingDeletesIt() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(volatile: ""), cursor: cursor(volatile: "hello"),
            contextBefore: "Dear Bob, hello", documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(5)])
        #expect(plan.cursor?.volatile == "")
    }

    @Test func contextMismatchDropsTheVolatileInsteadOfDeletingForeignText() {
        // The user moved the cursor or typed after our tentative text: the context no longer ends with it.
        let plan = ProxyEditPlanner.plan(
            state: hostState(volatile: "world"), cursor: cursor(volatile: "hello wo"),
            contextBefore: "hello wo and", documentID: "doc-A")
        #expect(plan.ops == [.insert(" world")]) // no deleteBackward at all
        #expect(plan.cursor?.volatile == " world")
    }

    // MARK: committed text

    @Test func committedTextIsInsertedAsASuffixPastTheCursor() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: "hello world "), cursor: cursor(committedCount: 6),
            contextBefore: "hello ", documentID: "doc-A")
        #expect(plan.ops == [.insert("world ")])
        #expect(plan.cursor?.committedCount == 12)
    }

    @Test func aVolatileThatTurnsFinalDoesNotRetypeItsSharedPrefix() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: "hello ", volatile: "wor"), cursor: cursor(volatile: "hello"),
            contextBefore: "hello", documentID: "doc-A")
        #expect(plan.ops == [.insert(" wor")])
        #expect(plan.cursor?.committedCount == 6)
        #expect(plan.cursor?.volatile == "wor")
    }

    @Test func catchUpAfterTheKeyboardReappearsInsertsEverythingMissed() {
        // The keyboard was hidden while the run went on: committed text and a new volatile arrive at once.
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: "hello world and more ", volatile: "and"),
            cursor: cursor(committedCount: 6, volatile: "wor"),
            contextBefore: "hello wor", documentID: "doc-A")
        #expect(plan.ops == [.insert("ld and more and")])
        #expect(plan.cursor?.committedCount == 21)
        #expect(plan.cursor?.volatile == "and")
    }

    // MARK: document binding

    @Test func aDifferentDocumentProducesNoOpsAndLeavesTheCursorAlone() {
        let bound = cursor(documentID: "doc-A", committedCount: 6)
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: "hello world "), cursor: bound,
            contextBefore: "hello ", documentID: "doc-B")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor == bound)
    }

    // The host app's field can be missing for a moment (the keyboard reappears after an app switch):
    // there is nothing to edit and nothing to bind to.
    @Test func noFieldProducesNoOpsAndLeavesTheCursorAlone() {
        let bound = cursor(committedCount: 6, volatile: "wor")
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: "hello world "), cursor: bound, contextBefore: "hello wor", documentID: nil)
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor == bound)
    }

    @Test func noFieldDoesNotBindANewRunOrMakeItFinal() {
        let fresh = ProxyEditPlanner.plan(
            state: hostState(committed: "hello "), cursor: nil, contextBefore: "", documentID: nil)
        #expect(fresh.ops.isEmpty && fresh.cursor == nil)
        let rebind = ProxyEditPlanner.plan(
            state: hostState(runID: "run-1", phase: .idle, committed: "hi "), cursor: cursor(runID: "run-0", committedCount: 3),
            contextBefore: "", documentID: nil)
        #expect(rebind.ops.isEmpty)
        #expect(rebind.cursor == cursor(runID: "run-0", committedCount: 3))
    }

    @Test func aNewRunRebindsToTheCurrentDocument() {
        let old = cursor(runID: "run-0", documentID: "doc-A", committedCount: 40)
        let plan = ProxyEditPlanner.plan(
            state: hostState(runID: "run-1", committed: "hi "), cursor: old,
            contextBefore: "", documentID: "doc-B")
        #expect(plan.ops == [.insert("hi ")])
        #expect(plan.cursor == cursor(runID: "run-1", documentID: "doc-B", committedCount: 3))
    }

    @Test func aNewRunRemovesTheLeftoverVolatileOfThePreviousRunWhenItStillEndsTheContext() {
        let old = cursor(runID: "run-0", volatile: "tent")
        let plan = ProxyEditPlanner.plan(
            state: hostState(runID: "run-1"), cursor: old, contextBefore: "foo tent", documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(4)])
        #expect(plan.cursor == cursor(runID: "run-1"))
    }

    @Test func aNewRunLeavesTheLeftoverVolatileAloneWhenTheContextMovedOn() {
        let old = cursor(runID: "run-0", volatile: "tent")
        let plan = ProxyEditPlanner.plan(
            state: hostState(runID: "run-1"), cursor: old, contextBefore: "foo tent bar", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
    }

    @Test func nothingIsPlannedWithoutARunOrForAnAppTarget() {
        let kept = cursor(committedCount: 2)
        let noRun = ProxyEditPlanner.plan(
            state: hostState(runID: nil, phase: .idle, committed: "hello"), cursor: kept,
            contextBefore: "", documentID: "doc-A")
        #expect(noRun.ops.isEmpty && noRun.cursor == kept)
        let app = ProxyEditPlanner.plan(
            state: hostState(target: .app, committed: "hello"), cursor: nil,
            contextBefore: "", documentID: "doc-A")
        #expect(app.ops.isEmpty && app.cursor == nil)
    }

    // MARK: separators

    @Test(arguments: [
        ("", "world "), ("Hello", " world "), ("Hello ", "world "), ("Hello\n", "world "),
    ])
    func aSpaceIsAddedAtTheStartOfARunOnlyWhenTheFieldNeedsOne(context: String, inserted: String) {
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: "world "), cursor: nil, contextBefore: context, documentID: "doc-A")
        #expect(plan.ops == [.insert(inserted)])
        #expect(plan.cursor?.committedCount == 6) // the added space is not part of `committed`
    }

    @Test func punctuationIsNeverSeparatedFromTheWordBeforeIt() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(committed: ". "), cursor: nil, contextBefore: "Hello", documentID: "doc-A")
        #expect(plan.ops == [.insert(". ")])
    }

    @Test func aVolatileAtTheStartOfARunCarriesTheSeparatorAndKeepsItWhileItGrows() {
        let first = ProxyEditPlanner.plan(
            state: hostState(volatile: "wor"), cursor: nil, contextBefore: "Hello", documentID: "doc-A")
        #expect(first.ops == [.insert(" wor")])
        #expect(first.cursor?.volatile == " wor")
        let second = ProxyEditPlanner.plan(
            state: hostState(volatile: "world"), cursor: first.cursor, contextBefore: "Hello wor",
            documentID: "doc-A")
        #expect(second.ops == [.insert("ld")])
        #expect(second.cursor?.volatile == " world")
    }

    // MARK: typing during a run

    @Test func aTypedKeyMidRunRemovesTheVolatileAndTheNextUpdateReAddsItAfterTheKey() {
        // Field: "hello wor" where "wor" is tentative.
        let typing = ProxyEditPlanner.prepareForTyping(
            cursor: cursor(committedCount: 6, volatile: "wor"), contextBefore: "hello wor")
        #expect(typing.ops == [.deleteBackward(3)])
        #expect(typing.cursor?.volatile == "")
        #expect(typing.cursor?.needsSeparator == true)

        // The keyboard inserts "X"; the next state update brings the volatile back after it.
        let next = ProxyEditPlanner.plan(
            state: hostState(committed: "hello ", volatile: "world"), cursor: typing.cursor,
            contextBefore: "hello X", documentID: "doc-A")
        #expect(next.ops == [.insert(" world")])
        #expect(next.cursor?.volatile == " world")
        #expect(next.cursor?.needsSeparator == true)

        // When it turns final, only the missing tail is typed.
        let final = ProxyEditPlanner.plan(
            state: hostState(committed: "hello world "), cursor: next.cursor,
            contextBefore: "hello X world", documentID: "doc-A")
        #expect(final.ops == [.insert(" ")])
        #expect(final.cursor?.committedCount == 12)
        #expect(final.cursor?.volatile == "")
        #expect(final.cursor?.needsSeparator == false)
    }

    @Test func typingWhenTheVolatileIsNoLongerThereOnlyMarksTheSeparator() {
        let typing = ProxyEditPlanner.prepareForTyping(
            cursor: cursor(committedCount: 6, volatile: "wor"), contextBefore: "hello wor and")
        #expect(typing.ops.isEmpty)
        #expect(typing.cursor?.volatile == "")
        #expect(typing.cursor?.needsSeparator == true)
    }

    @Test func typingWithoutACursorChangesNothing() {
        let typing = ProxyEditPlanner.prepareForTyping(cursor: nil, contextBefore: "hello")
        #expect(typing.ops.isEmpty && typing.cursor == nil)
    }

    // MARK: final confirmation

    @Test func theFinalStateIsConfirmedOnceEverythingLanded() {
        let final = hostState(phase: .idle, committed: "hello world ")
        let done = ProxyEditPlanner.plan(
            state: final, cursor: cursor(committedCount: 12), contextBefore: "hello world ", documentID: "doc-A")
        #expect(done.ops.isEmpty)
        #expect(done.cursor?.finalApplied == true)

        let catchingUp = ProxyEditPlanner.plan(
            state: final, cursor: cursor(committedCount: 6, volatile: "wor"), contextBefore: "hello wor",
            documentID: "doc-A")
        #expect(catchingUp.ops == [.insert("ld ")])
        #expect(catchingUp.cursor?.finalApplied == true)
    }

    @Test func aRunInProgressIsNeverConfirmedFinal() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(phase: .listening, committed: "hello "), cursor: cursor(), contextBefore: "",
            documentID: "doc-A")
        #expect(plan.cursor?.finalApplied == false)
    }

    @Test func aWrongDocumentIsNeverConfirmedFinal() {
        let plan = ProxyEditPlanner.plan(
            state: hostState(phase: .idle, committed: "hello "), cursor: cursor(committedCount: 6),
            contextBefore: "hello ", documentID: "doc-B")
        #expect(plan.cursor?.finalApplied == false)
    }
}
