import Testing
@testable import LegatoKeyboardCore

/// A `.live` run's state for the keyboard.
private func live(
    _ committed: String, _ volatile: String = "", phase: HostPhase = .listening
) -> HostState {
    var state = hostState(phase: phase, committed: committed, volatile: volatile)
    state.delivery = .live
    return state
}

/// "hello world " committed, "how are" tentative in the field, then the host cleared it (a chat app's Send).
private func sentWithTentative(_ tentative: String = "how are") throws -> AppliedCursor {
    let shown = cursor(committedCount: 12, volatile: tentative)
    return try #require(ProxyEditPlanner.fieldCleared(
        state: live("hello world ", tentative), cursor: shown, documentID: "doc-A", contextBefore: "", hasText: false))
}

private func plan(_ state: HostState, _ cursor: AppliedCursor, context: String = "") -> ProxyPlan {
    ProxyEditPlanner.plan(state: state, cursor: cursor, contextBefore: context, documentID: "doc-A")
}

@Suite struct LiveSentTentativeTests {
    @Test func theBoundaryRecordsTheTentativeTextTheFieldShowed() throws {
        let sent = try sentWithTentative()
        #expect(sent.sentBase == 12)
        #expect(sent.sentTentative == "how are", "it went with the message")
        #expect(sent.sentCount == 1)
    }

    @Test func theSentTentativeTextIsNotTypedIntoTheEmptiedField() throws {
        let sent = try sentWithTentative()
        #expect(plan(live("hello world ", "how are"), sent).ops.isEmpty)
        #expect(plan(live("hello world ", "how are you"), sent).ops.isEmpty, "nor the host's newer tentative text")
    }

    @Test func theCommitThatFinalizesItTypesOnlyWhatFollowsIt() throws {
        let p = plan(live("hello world how are you "), try sentWithTentative())
        #expect(p.ops == [.insert("you ")])
        #expect(p.cursor?.sentBase == 20, "the boundary moved past the sent phrase")
        #expect(p.cursor?.sentTentative == "")
    }

    @Test(arguments: [
        ("how are", "How are you? ", "you? "), // case and punctuation differ
        ("how ar", "how are you ", "you "), // the tentative text stopped mid-word
        ("how are", "so how are you ", "you "), // the engine put a word in front
        ("how or", "how are you doing ", "you doing "), // a word changed: the same number of words went
        ("how are", "how are ", ""), // exactly what was sent
    ])
    func aRevisedPhraseTypesOnlyThePartAfterWhatWasSent(tentative: String, commit: String, typed: String) throws {
        let p = plan(live("hello world " + commit), try sentWithTentative(tentative))
        #expect(p.ops == (typed.isEmpty ? [] : [.insert(typed)]))
    }

    @Test func itWaitsWhileTheCommittedTextCannotTellWhereTheSentPhraseEnds() throws {
        let sent = try sentWithTentative()
        let p = plan(live("hello world how ", "are you"), sent)
        #expect(p.ops.isEmpty)
        #expect(p.cursor?.sentTentative == "how are")
    }

    @Test func aRunThatEndsOnTheSentPhraseTypesNothingAndLands() throws {
        let p = plan(live("hello world how are", phase: .idle), try sentWithTentative())
        #expect(p.ops.isEmpty)
        #expect(p.cursor?.finalApplied == true)
    }
}

/// The keyboard's field through the typewriter reveal, with the host clearing it mid-run.
private struct SendRig {
    var reveal = TypewriterReveal()
    var field = ""
    var cursor: AppliedCursor?
    var lagging: Bool
    private var reported = ""

    init(lagging: Bool) { self.lagging = lagging }

    mutating func feed(_ state: HostState, elapsedMs: Double = 0) {
        let plan = reveal.plan(
            state: state, cursor: cursor, contextBefore: lagging ? reported : field, documentID: "doc-A",
            animated: true, elapsedMs: elapsedMs)
        reported = field
        for op in plan.ops {
            switch op {
            case .deleteBackward(let count): field.removeLast(min(count, field.count))
            case .insert(let text): field += text
            }
        }
        cursor = plan.cursor
    }

    mutating func drain(_ state: HostState) {
        feed(state)
        var n = 0
        while reveal.needsTicks, n < 400 {
            feed(state, elapsedMs: 33)
            n += 1
        }
    }

    /// The host sent the message: the field is empty, and the keyboard sees it.
    mutating func send(_ state: HostState) throws {
        field = ""
        reported = ""
        cursor = try #require(ProxyEditPlanner.fieldCleared(
            state: state, cursor: cursor, documentID: "doc-A", contextBefore: "", hasText: false))
    }
}

@Suite struct TypewriterRevealSentTentativeTests {
    @Test(arguments: [false, true])
    func theTentativeTextSentWithTheMessageNeverComesBack(lagging: Bool) throws {
        var rig = SendRig(lagging: lagging)
        rig.drain(live("hello world "))
        rig.drain(live("hello world ", "how are"))
        #expect(rig.field == "hello world how are")

        try rig.send(live("hello world ", "how are"))
        rig.drain(live("hello world ", "how are"))
        rig.drain(live("hello world ", "how are you"))
        #expect(rig.field == "", "nothing of the sent message is typed again")

        rig.drain(live("hello world how are you "))
        #expect(rig.field == "you ")
        rig.drain(live("hello world how are you ", phase: .idle))
        #expect(rig.field == "you ")
        #expect(rig.cursor?.finalApplied == true)
    }
}

@MainActor
@Suite struct HostLinkSentTentativeTests {
    @Test func aBoundaryWithOnlyTentativeTextReachesTheApp() {
        let store = LinkStore(MemoryLinkStore())
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        var heard: [(String, Int)] = []
        link.onSent = { heard.append(($0, $1)) }
        link.runStarted(id: "run-1", target: .keyboard, delivery: .live)
        link.update(committed: "", volatile: "hello")

        var applied = cursor(runID: "run-1", committedCount: 0)
        applied.sentTentative = "hello"
        applied.sentCount = 1
        store.write(applied, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        #expect(heard.map(\.0) == ["run-1"])
        #expect(heard.first?.1 == 0)
    }

    @Test func aSentBoundaryReportedAfterTheRunEndedStillReachesTheApp() {
        let store = LinkStore(MemoryLinkStore())
        let link = HostLink(store: store, post: { _ in }, now: { t0 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        var heard: [(String, Int)] = []
        link.onSent = { heard.append(($0, $1)) }
        link.runStarted(id: "run-1", target: .keyboard, delivery: .live)
        link.update(committed: "hello world ", volatile: "")
        link.runEnded(committed: "hello world ", finalText: "Hello world.")

        // The keyboard's report was on its way while the app published the final state.
        var applied = cursor(runID: "run-1", committedCount: 12)
        applied.sentBase = 12
        applied.sentCount = 1
        store.write(applied, forKey: LinkChannel.Key.applied)
        link.appliedDidChange()
        #expect(heard.map(\.0) == ["run-1"], "the app decides whether it is too late")
    }
}
