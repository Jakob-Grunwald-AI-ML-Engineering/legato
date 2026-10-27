import Foundation
import Testing
@testable import LegatoKeyboardCore

/// A `.live` run's state: the raw committed text plus the newest revision the app's live cleanup published.
private func liveState(
    phase: HostPhase = .listening, committed: String, volatile: String = "", revision: HostRevision?,
    finalText: String? = nil
) -> HostState {
    var state = hostState(phase: phase, committed: committed, volatile: volatile)
    state.delivery = .live
    state.revision = revision
    state.finalText = finalText
    return state
}

/// A cursor whose field shows `revision` (applied) for the run, then the raw text up to `committedCount`.
private func liveCursor(
    committedCount: Int, volatile: String = "", needsSeparator: Bool = false, shows revision: HostRevision? = nil
) -> AppliedCursor {
    var c = cursor(committedCount: committedCount, volatile: volatile, needsSeparator: needsSeparator)
    if let revision {
        c.revisionHandled = revision.n
        c.shownRevision = revision.n
        c.revisedEnd = revision.end
        c.revisedText = revision.text
    }
    return c
}

private let hello = HostRevision(n: 1, start: 0, raw: "hello world ", text: "Hello world. ")
private let whole = HostRevision(n: 2, start: 0, raw: "hello world how are you ", text: "Hello world. How are you? ")

@Suite struct ProxyEditPlannerLiveTests {
    @Test func aRevisionReplacesTheRunsTextAndTheRawTailFollows() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revision: hello),
            cursor: liveCursor(committedCount: 24), contextBefore: "Note: hello world how are you ", documentID: "doc-A")
        // The proxy only deletes backwards: the text after the first change goes out and back in.
        #expect(plan.ops == [.deleteBackward(24), .insert("Hello world. how are you ")])
        #expect(plan.cursor?.revisionHandled == 1)
        #expect(plan.cursor?.shownRevision == 1)
        #expect(plan.cursor?.revisionSkipped != true)
        #expect(plan.cursor?.committedCount == 24, "the cursor still counts raw committed characters")
    }

    @Test func aNewerRevisionReplacesWhatTheFieldShowsForTheRunAndKeepsTheSharedBeginning() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revision: whole),
            cursor: liveCursor(committedCount: 24, shows: hello), contextBefore: "Note: Hello world. how are you ",
            documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(12), .insert("How are you? ")])
        #expect(plan.cursor?.revisionHandled == 2)
        #expect(plan.cursor?.revisedText == "Hello world. How are you? ")
        #expect(plan.cursor?.revisedEnd == 24)
    }

    @Test func aLaterPassCanChangeAnEarlierPhrase() {
        let first = HostRevision(n: 1, start: 0, raw: "meet on friday ", text: "Meet on Friday. ")
        let fixed = HostRevision(n: 2, start: 0, raw: "meet on friday no wait thursday ", text: "Meet on Thursday. ")
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "meet on friday no wait thursday ", revision: fixed),
            cursor: liveCursor(committedCount: 32, shows: first), contextBefore: "Meet on Friday. no wait thursday ",
            documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(25), .insert("Thursday. ")])
    }

    @Test func theTentativeTextStaysAfterTheRevisedText() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", volatile: "and so", revision: hello),
            cursor: liveCursor(committedCount: 12, volatile: "and so"), contextBefore: "hello world and so",
            documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(18), .insert("Hello world. and so")])
        #expect(plan.cursor?.volatile == "and so")
    }

    @Test func aRevisionThatArrivesWithItsTextTypesTheCleanedTextStraightAway() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", revision: hello),
            cursor: nil, contextBefore: "Hi", documentID: "doc-A")
        #expect(plan.ops == [.insert(" Hello world. ")])
        #expect(plan.cursor?.committedCount == 12)
        #expect(plan.cursor?.revisionHandled == 1)
    }

    @Test func aRevisionAppliesOnceTheTextItCoversIsTyped() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revision: whole),
            cursor: liveCursor(committedCount: 12, shows: hello), contextBefore: "Hello world. ", documentID: "doc-A")
        // The plan types the rest first; then the revision covers typed text and applies.
        #expect(plan.cursor?.revisionHandled == 2)
        #expect(plan.ops == [.insert("How are you? ")])
    }

    @Test func aRevisionIsSkippedWhenTheUserTypedAfterTheDictation() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", revision: hello),
            cursor: liveCursor(committedCount: 12, needsSeparator: true), contextBefore: "hello world ok",
            documentID: "doc-A")
        #expect(plan.ops.isEmpty, "the field is left as the user made it")
        #expect(plan.cursor?.revisionHandled == 1, "never retried")
        #expect(plan.cursor?.revisionSkipped == true)
    }

    @Test func onceARevisionWasSkippedLaterOnesAreToo() {
        var skipped = liveCursor(committedCount: 24)
        skipped.revisionHandled = 1
        skipped.revisionSkipped = true
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revision: whole),
            cursor: skipped, contextBefore: "hello world how are you ", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.revisionHandled == 2)
    }

    @Test func aHandledRevisionIsNotAppliedAgain() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world ", revision: hello),
            cursor: liveCursor(committedCount: 12, shows: hello), contextBefore: "Hello world. ", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.revisionHandled == 1)
    }

    @Test func newCommittedTextAfterARevisionIsAppendedAsUsual() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how ", revision: hello),
            cursor: liveCursor(committedCount: 12, shows: hello), contextBefore: "Hello world. ", documentID: "doc-A")
        #expect(plan.ops == [.insert("how ")])
        #expect(plan.cursor?.committedCount == 16)
    }

    @Test func theFinalStateIsConfirmedWhenTheNewestRevisionLanded() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(
                phase: .idle, committed: "hello world how are you ", revision: whole,
                finalText: "Hello world. How are you?"),
            cursor: liveCursor(committedCount: 24, shows: hello), contextBefore: "Hello world. how are you ",
            documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(12), .insert("How are you? ")])
        #expect(plan.cursor?.finalApplied == true)
        #expect(plan.cursor?.finalReplaced == nil, "no separate swap in a live run")
    }

    @Test func theFinalStateIsNotConfirmedWhenARevisionWasSkipped() {
        var skipped = liveCursor(committedCount: 12, needsSeparator: true)
        skipped.revisionHandled = 1
        skipped.revisionSkipped = true
        let plan = ProxyEditPlanner.plan(
            state: liveState(phase: .idle, committed: "hello world ", revision: hello, finalText: "Hello world."),
            cursor: skipped, contextBefore: "hello world ok", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
        #expect(plan.cursor?.finalApplied == false, "the app copies the cleaned text instead")
    }

    @Test func otherDeliveriesIgnoreRevisions() {
        var state = liveState(committed: "hello world ", revision: hello)
        state.delivery = .replace
        let plan = ProxyEditPlanner.plan(
            state: state, cursor: cursor(committedCount: 12), contextBefore: "hello world ", documentID: "doc-A")
        #expect(plan.ops.isEmpty)
    }
}

@Suite struct LiveSentBoundaryTests {
    @Test func aClearedFieldIsASentBoundary() throws {
        let state = liveState(committed: "hello world ", revision: hello)
        let sent = try #require(ProxyEditPlanner.fieldCleared(
            state: state, cursor: liveCursor(committedCount: 12, shows: hello), documentID: "doc-A",
            contextBefore: "", hasText: false))
        #expect(sent.sentBase == 12)
        #expect(sent.sentShownRevision == 1, "the app records the sent text as the field showed it")
        #expect(sent.revisedEnd == 12 && sent.revisedText.isEmpty, "the field shows nothing of the run now")
        #expect(sent.volatile.isEmpty)
        #expect(sent.revisionSkipped == false)
    }

    @Test func tentativeTextAloneInTheFieldCountsAsTheRunsText() {
        let state = liveState(committed: "", volatile: "hello", revision: nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: liveCursor(committedCount: 0, volatile: "hello"), documentID: "doc-A",
            contextBefore: "", hasText: false) != nil)
    }

    @Test func anEditIsNotASentBoundary() {
        let state = liveState(committed: "hello world ", revision: hello)
        let shown = liveCursor(committedCount: 12, shows: hello)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: shown, documentID: "doc-A", contextBefore: "Hello wor", hasText: true) == nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: shown, documentID: "doc-A", contextBefore: "", hasText: true) == nil,
            "text after the caret: the user moved it to the start")
    }

    @Test func aFieldThatNeverShowedTheRunsTextIsNoBoundary() {
        let state = liveState(committed: "hello world ", revision: nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: liveCursor(committedCount: 0), documentID: "doc-A", contextBefore: "",
            hasText: false) == nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: nil, documentID: "doc-A", contextBefore: "", hasText: false) == nil)
    }

    @Test func onlyALiveRunInItsOwnFieldHasBoundaries() {
        var replace = liveState(committed: "hello world ", revision: nil)
        replace.delivery = .replace
        #expect(ProxyEditPlanner.fieldCleared(
            state: replace, cursor: liveCursor(committedCount: 12), documentID: "doc-A", contextBefore: "",
            hasText: false) == nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: liveState(committed: "hello world ", revision: nil), cursor: liveCursor(committedCount: 12),
            documentID: "doc-B", contextBefore: "", hasText: false) == nil)
        var landed = liveCursor(committedCount: 12)
        landed.finalApplied = true
        #expect(ProxyEditPlanner.fieldCleared(
            state: liveState(phase: .idle, committed: "hello world ", revision: nil),
            cursor: landed, documentID: "doc-A", contextBefore: "", hasText: false) == nil,
            "a finished run, all of it in the field, has nothing left to rebase")
    }

    @Test func aClearWhileTheFinalStateIsStillBeingTypedIsABoundary() {
        // The final state is out (idle) but the keyboard has typed only "hello world " of it so far.
        let final = liveState(phase: .idle, committed: "hello world how are you ", revision: nil)
        let typing = liveCursor(committedCount: 12)
        #expect(!typing.finalApplied)
        let sent = ProxyEditPlanner.fieldCleared(
            state: final, cursor: typing, documentID: "doc-A", contextBefore: "", hasText: false)
        #expect(sent?.sentBase == 12)
        #expect(sent?.sentCount == 1)
        let plan = ProxyEditPlanner.plan(state: final, cursor: sent, contextBefore: "", documentID: "doc-A")
        #expect(plan.ops == [.insert("how are you ")], "nothing of the sent part is typed again")
        #expect(plan.cursor?.finalApplied == true)
    }

    @Test func afterABoundaryTheRestStreamsIntoTheEmptyFieldWithoutASeparator() {
        var sent = liveCursor(committedCount: 12, shows: hello)
        sent = ProxyEditPlanner.fieldCleared(
            state: liveState(committed: "hello world ", revision: hello), cursor: sent, documentID: "doc-A",
            contextBefore: "", hasText: false)!
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revision: hello),
            cursor: sent, contextBefore: "", documentID: "doc-A")
        #expect(plan.ops == [.insert("how are you ")])
    }

    @Test func aRevisionOfTheSentTextIsDroppedNeverTyped() {
        var sent = liveCursor(committedCount: 12)
        sent.sentBase = 12
        sent.revisedEnd = 12
        let stale = HostRevision(n: 2, start: 0, raw: "hello world how are you ", text: "Hello world. How are you? ")
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you ", revision: stale),
            cursor: sent, contextBefore: "", documentID: "doc-A")
        #expect(plan.ops == [.insert("how are you ")], "only the raw text after the boundary goes in")
        #expect(plan.cursor?.revisionHandled == 2)
        #expect(plan.cursor?.revisionSkipped != true)
    }

    @Test func aRevisionAfterTheBoundaryReplacesOnlyTheTextAfterIt() {
        var sent = liveCursor(committedCount: 24)
        sent.sentBase = 12
        sent.revisedEnd = 12
        let after = HostRevision(n: 2, start: 12, raw: "how are you ", text: "How are you? ")
        let plan = ProxyEditPlanner.plan(
            state: liveState(phase: .idle, committed: "hello world how are you ", revision: after,
                             finalText: "Hello world. How are you?"),
            cursor: sent, contextBefore: "how are you ", documentID: "doc-A")
        #expect(plan.ops == [.deleteBackward(12), .insert("How are you? ")])
        #expect(plan.cursor?.finalApplied == true, "the app does not copy a sent run")
    }
}

@Suite struct DictationVersionsLiveTests {
    @Test func aLiveRunThatLandedShowsTheCleanedText() throws {
        var landed = liveCursor(committedCount: 12, shows: hello)
        landed.finalApplied = true
        let state = liveState(phase: .idle, committed: "hello world ", revision: hello, finalText: "Hello world.")
        let versions = try #require(DictationVersions.landed(state: state, cursor: landed))
        #expect(versions.texts == ["hello world", "Hello world."])
        #expect(versions.current == 1)
        #expect(versions.shown == "Hello world. ")
    }

    @Test func afterASentBoundaryTheVersionsCoverOnlyTheTextAfterIt() throws {
        var landed = liveCursor(committedCount: 24)
        landed.sentBase = 12
        landed.revisedEnd = 24
        landed.revisedText = "How are you? "
        landed.shownRevision = 2
        landed.revisionHandled = 2
        landed.finalApplied = true
        let state = liveState(
            phase: .idle, committed: "hello world how are you ",
            revision: HostRevision(n: 2, start: 12, raw: "how are you ", text: "How are you? "),
            finalText: "Hello world. How are you?")
        let versions = try #require(DictationVersions.landed(state: state, cursor: landed))
        #expect(versions.texts == ["how are you", "How are you?"])
        #expect(versions.shown == "How are you? ")
    }

    @Test func aRunSentWholeHasNoVersions() {
        var landed = liveCursor(committedCount: 12)
        landed.sentBase = 12
        landed.revisedEnd = 12
        landed.finalApplied = true
        let state = liveState(phase: .idle, committed: "hello world ", revision: hello, finalText: "Hello world.")
        #expect(DictationVersions.landed(state: state, cursor: landed) == nil)
    }
}

@Suite struct AppliedCursorCodingTests {
    @Test func aCursorSavedBeforeLiveCleanupStillDecodes() throws {
        let json = #"{"runID":"r","documentID":"d","committedCount":3,"volatile":"","needsSeparator":false,"finalApplied":true}"#
        let decoded = try JSONDecoder().decode(AppliedCursor.self, from: Data(json.utf8))
        #expect(decoded.committedCount == 3)
        #expect(decoded.revisionHandled == 0)
        #expect(decoded.revisionSkipped == false)
        #expect(decoded.sentBase == 0)
        #expect(decoded.revisedText == "")
    }
}

@MainActor
@Suite struct HostLinkRevisionTests {
    @Test func theNewestRevisionIsPublishedAtOnceKeptInTheFinalStateAndClearedForTheNextRun() {
        let store = LinkStore(MemoryLinkStore())
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        var host: HostState? { store.read(HostState.self, forKey: LinkChannel.Key.host) }

        link.runStarted(id: "run-1", target: .keyboard, delivery: .live)
        link.update(committed: "hello world how are you ", volatile: "")
        link.revise(hello)
        #expect(host?.revision == hello)
        link.revise(whole)
        #expect(host?.revision == whole, "only the newest is kept: it replaces the run's text")
        #expect(host?.committed == "hello world how are you ", "committed stays raw")

        link.runEnded(committed: "hello world how are you ", finalText: "Hello world. How are you?")
        #expect(host?.revision == whole, "a keyboard that was away still gets it")

        link.runStarted(id: "run-2", target: .keyboard, delivery: .live)
        #expect(host?.revision == nil)
    }

    @Test func aSentBoundaryTheKeyboardReportsReachesTheAppOnce() {
        let store = LinkStore(MemoryLinkStore())
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        var heard: [(String, Int, Int)] = []
        link.onSent = { heard.append(($0, $1, $2)) }
        link.runStarted(id: "run-1", target: .keyboard, delivery: .live)
        link.update(committed: "hello world ", volatile: "")

        var applied = cursor(runID: "run-1", committedCount: 12)
        store.write(applied, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        #expect(heard.isEmpty, "no boundary yet")

        applied.sentBase = 12
        applied.sentShownRevision = 1
        store.write(applied, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        link.appliedDidChange()
        #expect(heard.map(\.0) == ["run-1"])
        #expect(heard.first?.1 == 12 && heard.first?.2 == 1)

        var other = applied
        other.runID = "run-0"
        other.sentBase = 30
        store.write(other, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        #expect(heard.count == 1, "another run's boundary is not this run's")
    }
}
