import Foundation
import Testing
@testable import LegatoKeyboardCore

/// A `.live` run's state: the raw committed text.
private func liveState(
    phase: HostPhase = .listening, committed: String, volatile: String = "", finalText: String? = nil
) -> HostState {
    var state = hostState(phase: phase, committed: committed, volatile: volatile)
    state.delivery = .live
    state.finalText = finalText
    return state
}

private func liveCursor(committedCount: Int, volatile: String = "", needsSeparator: Bool = false) -> AppliedCursor {
    cursor(committedCount: committedCount, volatile: volatile, needsSeparator: needsSeparator)
}

@Suite struct ProxyEditPlannerLiveTests {
    @Test func newCommittedTextIsAppendedAsUsual() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how "),
            cursor: liveCursor(committedCount: 12), contextBefore: "hello world ", documentID: "doc-A")
        #expect(plan.ops == [.insert("how ")])
        #expect(plan.cursor?.committedCount == 16)
    }

    @Test func theFinalStateOfALiveRunIsConfirmedOnceTheStreamedTextLandedWithoutASwap() {
        let plan = ProxyEditPlanner.plan(
            state: liveState(phase: .idle, committed: "hello world how are you ", finalText: "Hello world. How are you?"),
            cursor: liveCursor(committedCount: 12), contextBefore: "hello world ", documentID: "doc-A")
        #expect(plan.ops == [.insert("how are you ")])
        #expect(plan.cursor?.finalApplied == true)
        #expect(plan.cursor?.finalReplaced == nil, "no separate swap in a live run")
    }
}

@Suite struct LiveSentBoundaryTests {
    @Test func aClearedFieldIsASentBoundary() throws {
        let state = liveState(committed: "hello world ")
        let sent = try #require(ProxyEditPlanner.fieldCleared(
            state: state, cursor: liveCursor(committedCount: 12), documentID: "doc-A",
            contextBefore: "", hasText: false))
        #expect(sent.sentBase == 12)
        #expect(sent.volatile.isEmpty)
    }

    @Test func tentativeTextAloneInTheFieldCountsAsTheRunsText() {
        let state = liveState(committed: "", volatile: "hello")
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: liveCursor(committedCount: 0, volatile: "hello"), documentID: "doc-A",
            contextBefore: "", hasText: false) != nil)
    }

    @Test func anEditIsNotASentBoundary() {
        let state = liveState(committed: "hello world ")
        let shown = liveCursor(committedCount: 12)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: shown, documentID: "doc-A", contextBefore: "Hello wor", hasText: true) == nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: shown, documentID: "doc-A", contextBefore: "", hasText: true) == nil,
            "text after the caret: the user moved it to the start")
    }

    @Test func aFieldThatNeverShowedTheRunsTextIsNoBoundary() {
        let state = liveState(committed: "hello world ")
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: liveCursor(committedCount: 0), documentID: "doc-A", contextBefore: "",
            hasText: false) == nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: state, cursor: nil, documentID: "doc-A", contextBefore: "", hasText: false) == nil)
    }

    @Test func onlyALiveRunInItsOwnFieldHasBoundaries() {
        var replace = liveState(committed: "hello world ")
        replace.delivery = .replace
        #expect(ProxyEditPlanner.fieldCleared(
            state: replace, cursor: liveCursor(committedCount: 12), documentID: "doc-A", contextBefore: "",
            hasText: false) == nil)
        #expect(ProxyEditPlanner.fieldCleared(
            state: liveState(committed: "hello world "), cursor: liveCursor(committedCount: 12),
            documentID: "doc-B", contextBefore: "", hasText: false) == nil)
        var landed = liveCursor(committedCount: 12)
        landed.finalApplied = true
        #expect(ProxyEditPlanner.fieldCleared(
            state: liveState(phase: .idle, committed: "hello world "),
            cursor: landed, documentID: "doc-A", contextBefore: "", hasText: false) == nil,
            "a finished run, all of it in the field, has nothing left to rebase")
    }

    @Test func aClearWhileTheFinalStateIsStillBeingTypedIsABoundary() {
        // The final state is out (idle) but the keyboard has typed only "hello world " of it so far.
        let final = liveState(phase: .idle, committed: "hello world how are you ")
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
        var sent = liveCursor(committedCount: 12)
        sent = ProxyEditPlanner.fieldCleared(
            state: liveState(committed: "hello world "), cursor: sent, documentID: "doc-A",
            contextBefore: "", hasText: false)!
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you "),
            cursor: sent, contextBefore: "", documentID: "doc-A")
        #expect(plan.ops == [.insert("how are you ")])
    }

    @Test func textBeforeTheBoundaryIsNeverTypedAgain() {
        var sent = liveCursor(committedCount: 12)
        sent.sentBase = 12
        let plan = ProxyEditPlanner.plan(
            state: liveState(committed: "hello world how are you "),
            cursor: sent, contextBefore: "", documentID: "doc-A")
        #expect(plan.ops == [.insert("how are you ")], "only the raw text after the boundary goes in")
    }
}

@Suite struct DictationVersionsLiveTests {
    @Test func aLiveRunThatLandedShowsTheCleanedText() throws {
        var landed = liveCursor(committedCount: 12)
        landed.finalApplied = true
        let state = liveState(phase: .idle, committed: "hello world ", finalText: "Hello world.")
        let versions = try #require(DictationVersions.landed(state: state, cursor: landed))
        #expect(versions.texts == ["hello world", "Hello world."])
        #expect(versions.current == 1)
        #expect(versions.shown == "Hello world. ")
    }

    @Test func afterASentBoundaryTheVersionsCoverOnlyTheTextAfterIt() throws {
        var landed = liveCursor(committedCount: 24)
        landed.sentBase = 12
        landed.finalApplied = true
        let state = liveState(phase: .idle, committed: "hello world how are you ")
        let versions = try #require(DictationVersions.landed(state: state, cursor: landed))
        #expect(versions.texts == ["how are you"])
        #expect(versions.shown == "how are you ")
    }

    @Test func aRunSentWholeHasNoVersions() {
        var landed = liveCursor(committedCount: 12)
        landed.sentBase = 12
        landed.finalApplied = true
        let state = liveState(phase: .idle, committed: "hello world ", finalText: "Hello world.")
        #expect(DictationVersions.landed(state: state, cursor: landed) == nil)
    }
}

@Suite struct AppliedCursorCodingTests {
    @Test func aCursorSavedBeforeLiveCleanupStillDecodes() throws {
        let json = #"{"runID":"r","documentID":"d","committedCount":3,"volatile":"","needsSeparator":false,"finalApplied":true}"#
        let decoded = try JSONDecoder().decode(AppliedCursor.self, from: Data(json.utf8))
        #expect(decoded.committedCount == 3)
        #expect(decoded.sentBase == 0)
    }

    @Test func aCursorSavedWithTheRemovedRevisionFieldsStillDecodes() throws {
        let json = """
            {"runID":"r","documentID":"d","committedCount":24,"volatile":"","needsSeparator":false,"finalApplied":true,            "revisionHandled":2,"revisionSkipped":true,"shownRevision":2,"revisedEnd":24,"revisedText":"Hi. ",            "sentBase":12,"sentShownRevision":1,"sentTentative":"how","sentCount":1}
            """
        let decoded = try JSONDecoder().decode(AppliedCursor.self, from: Data(json.utf8))
        #expect(decoded.committedCount == 24)
        #expect(decoded.sentBase == 12)
        #expect(decoded.sentTentative == "how")
        #expect(decoded.sentCount == 1)
    }
}

@Suite struct HostDeliveryCodingTests {
    @Test(arguments: [("replace", HostDelivery.replace), ("live", .live), ("hold", .live), ("clipboard", .live)])
    func aDeliveryDecodesAndTheRemovedModesReadAsLive(raw: String, expected: HostDelivery) throws {
        let decoded = try JSONDecoder().decode(HostDelivery.self, from: Data("\"\(raw)\"".utf8))
        #expect(decoded == expected)
    }

    @Test func anUnknownDeliveryDoesNotDecode() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostDelivery.self, from: Data("\"other\"".utf8)) }
    }

    @Test func aStateFromAnOlderBuildWithAHoldRunAndARevisionDecodes() throws {
        var state = hostState(phase: .listening, committed: "hi")
        state.delivery = .live
        var json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"live\"", with: "\"hold\"")
        json.removeLast()
        json += #","fieldEdits":true,"revision":{"n":1,"start":0,"raw":"hi","text":"Hi."}}"#
        let decoded = try JSONDecoder().decode(HostState.self, from: Data(json.utf8))
        #expect(decoded.delivery == .live)
        #expect(decoded.committed == "hi")
    }
}

@MainActor
@Suite struct HostLinkSentBoundaryTests {
    @Test func aSentBoundaryTheKeyboardReportsReachesTheAppOnce() {
        let store = LinkStore(MemoryLinkStore())
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        var heard: [(String, Int)] = []
        link.onSent = { heard.append(($0, $1)) }
        link.runStarted(id: "run-1", target: .keyboard, delivery: .live)
        link.update(committed: "hello world ", volatile: "")

        var applied = cursor(runID: "run-1", committedCount: 12)
        store.write(applied, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        #expect(heard.isEmpty, "no boundary yet")

        applied.sentBase = 12
        store.write(applied, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        link.appliedDidChange()
        #expect(heard.map(\.0) == ["run-1"])
        #expect(heard.first?.1 == 12)

        var other = applied
        other.runID = "run-0"
        other.sentBase = 30
        store.write(other, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        #expect(heard.count == 1, "another run's boundary is not this run's")
    }
}
