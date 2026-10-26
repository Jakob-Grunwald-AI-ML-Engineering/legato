import Foundation
import Testing
@testable import LegatoKeyboardCore

/// A `.live` run's state: the raw committed text plus the revisions the app's live cleanup published.
private func liveState(
    phase: HostPhase = .listening, committed: String, volatile: String = "", revisions: [HostRevision],
    finalText: String? = nil
) -> HostState {
    var state = hostState(phase: phase, committed: committed, volatile: volatile)
    state.delivery = .live
    state.revisions = revisions
    state.finalText = finalText
    return state
}

private func liveCursor(
    committedCount: Int, volatile: String = "", needsSeparator: Bool = false, handled: Int = 0
) -> AppliedCursor {
    var c = cursor(committedCount: committedCount, volatile: volatile, needsSeparator: needsSeparator)
    c.revisionsHandled = handled
    return c
}

private let helloRevision = HostRevision(start: 0, raw: "hello world ", text: "Hello world. ")

@Suite struct ProxyEditPlannerLiveTests {
    @Test func aRevisionReplacesItsSegmentWhileTheFieldStillShowsIt() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revisions: [helloRevision]),
            cursor: liveCursor(committedCount: 24), contextBefore: "Note: hello world how are you ", documentID: "doc-A")
        // The later segment goes out and back in after the cleaned one: the proxy only deletes backwards.
        #expect(plan.ops == [.deleteBackward(24), .insert("Hello world. how are you ")])
        #expect(plan.cursor?.revisionsHandled == 1)
        #expect(plan.cursor?.revisionSkipped != true)
        #expect(plan.cursor?.committedCount == 24, "the cursor still counts raw committed characters")
    }

    @Test func theTentativeTextStaysAfterTheRevisedText() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", volatile: "and so", revisions: [helloRevision]),
            cursor: liveCursor(committedCount: 12, volatile: "and so"), contextBefore: "hello world and so",
            documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(18), .insert("Hello world. and so")])
        #expect(plan.cursor?.volatile == "and so")
    }

    @Test func aRevisionThatArrivesWithItsSegmentTypesTheCleanedTextStraightAway() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", revisions: [helloRevision]),
            cursor: nil, contextBefore: "Hi", documentID: "doc-A")
        #expect(plan.ops == [.insert(" Hello world. ")])
        #expect(plan.cursor?.committedCount == 12)
        #expect(plan.cursor?.revisionsHandled == 1)
    }

    @Test func aRevisionIsSkippedWhenTheUserTypedAfterTheDictation() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", revisions: [helloRevision]),
            cursor: liveCursor(committedCount: 12, needsSeparator: true), contextBefore: "hello world ok",
            documentID: "doc-A")
        #expect(plan.ops.isEmpty, "the field is left as the user made it")
        #expect(plan.cursor?.revisionsHandled == 1, "never retried")
        #expect(plan.cursor?.revisionSkipped == true)
    }

    @Test func aLaterRevisionStillAppliesAfterOneWasSkipped() {
        // The user typed "ok" between the two segments: the first one's span has moved, the second's has not.
        let revisions = [
            HostRevision(start: 0, raw: "one ", text: "One. "),
            HostRevision(start: 4, raw: "two ", text: "Two. "),
        ]
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "one two ", revisions: revisions),
            cursor: liveCursor(committedCount: 8), contextBefore: "one ok two ", documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(4), .insert("Two. ")])
        #expect(plan.cursor?.revisionsHandled == 2)
        #expect(plan.cursor?.revisionSkipped == true)
    }

    @Test func aHandledRevisionIsNotAppliedAgain() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", revisions: [helloRevision]),
            cursor: liveCursor(committedCount: 12, handled: 1), contextBefore: "Hello world. ", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.revisionsHandled == 1)
    }

    @Test func newCommittedTextAfterARevisionIsAppendedAsUsual() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how ", revisions: [helloRevision]),
            cursor: liveCursor(committedCount: 12, handled: 1), contextBefore: "Hello world. ", documentID: "doc-A")
        #expect(plan.ops == [.insert("how ")])
        #expect(plan.cursor?.committedCount == 16)
    }

    @Test func theFinalStateIsConfirmedWhenEveryRevisionLanded() {
        let tail = HostRevision(start: 12, raw: "how are you ", text: "How are you? ")
        let plan = ProxyEditPlanner.plan(
            state: liveState(
                phase: .idle, committed: "hello world how are you ", revisions: [helloRevision, tail],
                finalText: "Hello world. How are you?"),
            cursor: liveCursor(committedCount: 24, handled: 1), contextBefore: "Hello world. how are you ",
            documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(12), .insert("How are you? ")])
        #expect(plan.cursor?.finalApplied == true)
        #expect(plan.cursor?.finalReplaced == nil, "no whole-span swap in a live run")
    }

    @Test func theFinalStateIsNotConfirmedWhenARevisionWasSkipped() {
        var skipped = liveCursor(committedCount: 12, needsSeparator: true, handled: 1)
        skipped.revisionSkipped = true
        let plan = ProxyEditPlanner.plan(
            state: liveState(phase: .idle, committed: "hello world ", revisions: [helloRevision], finalText: "Hello world."),
            cursor: skipped, contextBefore: "hello world ok", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.finalApplied == false, "the app copies the cleaned text instead")
    }

    @Test func otherDeliveriesIgnoreRevisions() {
        var state = liveState(committed: "hello world ", revisions: [helloRevision])
        state.delivery = .replace
        let plan = ProxyEditPlanner.plan(
            state: state, cursor: cursor(committedCount: 12), contextBefore: "hello world ", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
    }
}

@Suite struct DictationVersionsLiveTests {
    @Test func aLiveRunThatLandedShowsTheCleanedText() throws {
        var landed = liveCursor(committedCount: 12, handled: 1)
        landed.finalApplied = true
        let state = liveState(phase: .idle, committed: "hello world ", revisions: [helloRevision], finalText: "Hello world.")
        let versions = try #require(DictationVersions.landed(state: state, cursor: landed))
        #expect(versions.texts == ["hello world", "Hello world."])
        #expect(versions.current == 1)
        #expect(versions.shown == "Hello world. ")
    }
}

@Suite struct AppliedCursorCodingTests {
    @Test func aCursorSavedBeforeLiveCleanupStillDecodes() throws {
        let json = #"{"runID":"r","documentID":"d","committedCount":3,"volatile":"","needsSeparator":false,"finalApplied":true}"#
        let decoded = try JSONDecoder().decode(AppliedCursor.self, from: Data(json.utf8))
        #expect(decoded.committedCount == 3)
        #expect(decoded.revisionsHandled == 0)
        #expect(decoded.revisionSkipped == false)
    }
}

@MainActor
@Suite struct HostLinkRevisionTests {
    @Test func aRevisionIsPublishedAtOnceKeptInTheFinalStateAndClearedForTheNextRun() {
        let store = LinkStore(MemoryLinkStore())
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        var host: HostState? { store.read(HostState.self, forKey: LinkChannel.Key.host) }

        link.runStarted(id: "run-1", target: .keyboard, delivery: .live)
        link.update(committed: "hello world ", volatile: "")
        link.revise(helloRevision)
        #expect(host?.revisions == [helloRevision])
        #expect(host?.committed == "hello world ", "committed stays raw")

        link.runEnded(committed: "hello world ", finalText: "Hello world.")
        #expect(host?.revisions == [helloRevision], "a keyboard that was away still gets every revision")

        link.runStarted(id: "run-2", target: .keyboard, delivery: .live)
        #expect(host?.revisions == nil)
    }
}
