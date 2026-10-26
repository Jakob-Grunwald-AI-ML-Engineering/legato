import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LinkHostApplyDecisionTests {
    private let now = t0.addingTimeInterval(1)

    private func decide(
        host: HostState?, cursor: AppliedCursor? = nil, visible: Bool = true, documentID: String? = "doc-A"
    ) -> HostApplyDecision {
        HostApplyDecision.decide(host: host, cursor: cursor, visible: visible, documentID: documentID, now: now)
    }

    @Test func aLiveRunForTheKeyboardIsAppliedEvenIfThisKeyboardNeverAskedForIt() {
        // Started from the Action Button or the Live Activity: no cursor, the keyboard sent no request.
        #expect(decide(host: hostState(phase: .listening, beatAt: now)) == .apply)
    }

    @Test func aHiddenKeyboardAppliesNothing() {
        #expect(decide(host: hostState(beatAt: now), visible: false) == .skip(.notVisible))
    }

    @Test func noHostStateAppliesNothing() {
        #expect(decide(host: nil) == .skip(.noHost))
    }

    @Test func aRunForTheAppsOwnScreenIsNotTyped() {
        #expect(decide(host: hostState(target: .app, beatAt: now)) == .skip(.otherTarget))
    }

    @Test func noBoundFieldAppliesNothing() {
        #expect(decide(host: hostState(beatAt: now), documentID: nil) == .skip(.noDocument))
    }

    @Test func aRunningStateWithAStaleBeatBelongsToADeadApp() {
        let stale = hostState(phase: .listening, beatAt: now.addingTimeInterval(-LinkChannel.beatFreshness - 0.1))
        #expect(decide(host: stale) == .skip(.stale))
    }

    @Test func theFinalStateOfARunThisKeyboardNeverSawIsNotTyped() {
        let final = hostState(runID: "old", phase: .idle, committed: "hello", beatAt: t0)
        #expect(decide(host: final) == .skip(.unseenFinal))
        #expect(decide(host: final, cursor: cursor(runID: "other")) == .skip(.unseenFinal))
    }

    @Test func aFinalStateThatIsAFreshInsertRequestIsAppliedWithoutHavingFollowedTheRun() {
        // The Live Activity's Insert button: the keyboard never saw this run, the app asked for it.
        let insert = hostState(runID: "ins-1", phase: .idle, committed: "hello", beatAt: now, insertAt: now)
        #expect(decide(host: insert) == .apply)
    }

    @Test func anOldInsertRequestIsNotAppliedByAKeyboardThatAppearsLater() {
        let insert = hostState(
            runID: "ins-1", phase: .idle, committed: "hello", beatAt: t0,
            insertAt: now.addingTimeInterval(-LinkChannel.insertMaxAge - 1))
        #expect(decide(host: insert) == .skip(.unseenFinal))
    }

    @Test func aFreshInsertRequestStillNeedsAVisibleKeyboardAndABoundField() {
        let insert = hostState(runID: "ins-1", phase: .idle, committed: "hello", beatAt: now, insertAt: now)
        #expect(decide(host: insert, visible: false) == .skip(.notVisible))
        #expect(decide(host: insert, documentID: nil) == .skip(.noDocument))
    }

    @Test func theFinalStateOfARunThisKeyboardFollowsIsApplied() {
        let final = hostState(runID: "run-1", phase: .idle, committed: "hello", beatAt: t0)
        #expect(decide(host: final, cursor: cursor(runID: "run-1")) == .apply)
    }
}
