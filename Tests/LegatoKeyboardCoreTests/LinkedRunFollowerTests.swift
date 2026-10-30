import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// Which runs the keyboard publishes its feed for and takes the app's edits from (review L6 #1, #2): only a run
/// whose cleaned text the app writes over the link (Live, Replace); never a run without cleanup; stopped (without a last flush) when the app scrubs the link.
struct LinkedRunFollowerTests {
    func host(
        _ runID: String? = "run-1", delivery: HostDelivery? = .live,
        target: HostTarget = .keyboard, phase: HostPhase = .listening
    ) -> HostState {
        var state = hostState(runID: runID, phase: phase, target: target)
        state.delivery = delivery
        return state
    }

    @Test(arguments: [HostDelivery.live, .replace])
    func aRunTheAppWritesOverTheLinkIsFollowed(_ delivery: HostDelivery) {
        var follower = LinkedRunFollower()
        #expect(follower.hostChanged(host(delivery: delivery)) == .follow("run-1"))
        #expect(follower.runID == "run-1")
        #expect(follower.hostChanged(host(delivery: delivery)) == .none)  // once
    }

    @Test func aRunWithoutCleanupIsNotFollowed() {
        var follower = LinkedRunFollower()
        #expect(follower.hostChanged(host(delivery: nil)) == .none)
        #expect(follower.runID == nil)
    }

    @Test func aRunForTheAppIsNotFollowed() {
        var follower = LinkedRunFollower()
        #expect(follower.hostChanged(host(target: .app)) == .none)
        #expect(follower.runID == nil)
    }

    /// The next run that is not on the link ends the old one (its last batch still goes out).
    @Test func anotherRunStopsFollowing() {
        var follower = LinkedRunFollower()
        _ = follower.hostChanged(host())
        #expect(follower.hostChanged(host("run-2", delivery: nil)) == .stop(flush: true))
        #expect(follower.runID == nil)
    }

    /// The scrub (no run any more): the link's text is gone, so nothing more is written, not even a last batch.
    @Test func theScrubStopsWithoutALastBatch() {
        var follower = LinkedRunFollower()
        _ = follower.hostChanged(host())
        #expect(follower.hostChanged(host(nil, delivery: nil, phase: .idle)) == .stop(flush: false))
        #expect(follower.hostChanged(host(nil, delivery: nil, phase: .idle)) == .none)
    }

    /// The run's final state keeps it followed: the app's stop still sends edits and reads their outcomes.
    @Test func theRunsFinalStateKeepsItFollowed() {
        var follower = LinkedRunFollower()
        _ = follower.hostChanged(host())
        #expect(follower.hostChanged(host(phase: .idle)) == .none)
        #expect(follower.runID == "run-1")
    }

    /// The link delivers edits at least once: each is taken once per run.
    @Test func eachEditIsTakenOnce() {
        var follower = LinkedRunFollower()
        _ = follower.hostChanged(host())
        let a = EditTransaction(origin: .agent, owner: "run-1", base: FieldVersion(0), steps: [])
        let b = EditTransaction(origin: .agent, owner: "run-1", base: FieldVersion(0), steps: [])
        #expect(follower.fresh([a]) == [a])
        #expect(follower.fresh([a, b]) == [b])
        _ = follower.hostChanged(host("run-2"))
        #expect(follower.fresh([a]) == [a])  // a new run starts over
    }
}
