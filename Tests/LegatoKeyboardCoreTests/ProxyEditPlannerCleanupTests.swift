import Testing
@testable import LegatoKeyboardCore

/// A run's final state after post-processing: `committed` is the raw text as streamed, `finalText` the
/// cleaned text when it differs.
private func finalState(
    committed: String, finalText: String?, delivery: HostDelivery?
) -> HostState {
    var state = hostState(phase: .idle, committed: committed)
    state.finalText = finalText
    state.delivery = delivery
    return state
}

@Suite struct ProxyEditPlannerReplaceTests {
    @Test func theStreamedTextIsSwappedForTheCleanedTextInOneEdit() {
        let plan = ProxyEditPlanner.plan(
            state: finalState(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace),
            cursor: cursor(committedCount: 15), contextBefore: "Dear Bob, um hello world ", documentID: "doc-A")
        // The trailing space the engine left stays after the cleaned text.
        #expect(plan.ops == [.deleteBackward(15), .insert("Hello, world. ")])
        #expect(plan.cursor?.finalApplied == true)
        #expect(plan.cursor?.finalReplaced == true)
    }

    @Test func aSharedBeginningIsNotRetyped() {
        let plan = ProxyEditPlanner.plan(
            state: finalState(committed: "hello world", finalText: "hello, world.", delivery: .replace),
            cursor: cursor(committedCount: 11), contextBefore: "hello world", documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(6), .insert(", world.")])
        #expect(plan.cursor?.finalApplied == true)
    }

    @Test func committedTextThatArrivesWithTheFinalStateIsTypedThenSwapped() {
        let plan = ProxyEditPlanner.plan(
            state: finalState(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace),
            cursor: cursor(committedCount: 9), contextBefore: "um hello ", documentID: "doc-A")
        #expect(plan.ops == [.insert("world "), .deleteBackward(15), .insert("Hello, world. ")])
        #expect(plan.cursor?.finalApplied == true)
        #expect(plan.cursor?.committedCount == 15)
    }

    @Test func aFieldThatNoLongerEndsWithTheStreamedTextIsLeftAloneAndNotConfirmed() {
        // The user typed after the dictation: the cleaned text goes to the clipboard instead (the app sees
        // no confirmation).
        let plan = ProxyEditPlanner.plan(
            state: finalState(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace),
            cursor: cursor(committedCount: 15, needsSeparator: true),
            contextBefore: "um hello world and more", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.finalApplied == false)
        #expect(plan.cursor?.finalReplaced == false)
    }

    @Test func planningTheSameFinalStateAgainChangesNothing() {
        let state = finalState(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace)
        let first = ProxyEditPlanner.plan(
            state: state, cursor: cursor(committedCount: 15), contextBefore: "um hello world ", documentID: "doc-A")
        let again = ProxyEditPlanner.plan(
            state: state, cursor: first.cursor, contextBefore: "Hello, world. ", documentID: "doc-A")
        #expect(again.ops.isEmpty)
        #expect(again.cursor == first.cursor)
    }

    @Test func aSwapThatCouldNotHappenIsNotRetried() {
        let state = finalState(committed: "um hello world ", finalText: "Hello, world.", delivery: .replace)
        let failed = ProxyEditPlanner.plan(
            state: state, cursor: cursor(committedCount: 15), contextBefore: "um hello world typed", documentID: "doc-A")
        let again = ProxyEditPlanner.plan(
            state: state, cursor: failed.cursor, contextBefore: "um hello world ", documentID: "doc-A")
        #expect(again.ops.isEmpty)
        #expect(again.cursor?.finalApplied == false)
    }

    @Test func withoutACleanedTextTheFinalStateLandsAsBefore() {
        let plan = ProxyEditPlanner.plan(
            state: finalState(committed: "hello ", finalText: nil, delivery: .replace),
            cursor: cursor(committedCount: 6), contextBefore: "hello ", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.finalApplied == true)
        #expect(plan.cursor?.finalReplaced == nil)
    }
}
