import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Whether a keyboard may follow the host's state: a state left behind by a dead app must not be typed.
@Suite struct HostFreshnessTests {
    private let now = t0.addingTimeInterval(10)

    @Test(arguments: [HostPhase.starting, .listening, .finishing])
    func aRunningStateWithAStaleBeatIsNotFollowed(phase: HostPhase) {
        let stale = hostState(phase: phase, committed: "words", beatAt: now.addingTimeInterval(-LinkChannel.beatFreshness - 0.1))
        #expect(!stale.isLive(now: now))
    }

    @Test(arguments: [HostPhase.starting, .listening, .finishing])
    func aRunningStateWithAFreshBeatIsFollowed(phase: HostPhase) {
        #expect(hostState(phase: phase, beatAt: now.addingTimeInterval(-2.4)).isLive(now: now))
        #expect(hostState(phase: phase, beatAt: now).isLive(now: now))
    }

    @Test func anIdleStateIsFollowedWhateverItsAge() {
        // The final state of a run that ended: the beat stops with the run, so it is always old.
        #expect(hostState(phase: .idle, committed: "words", beatAt: now.addingTimeInterval(-60)).isLive(now: now))
    }

    @Test func anInsertRequestIsFreshOnlyBriefly() {
        #expect(!hostState(phase: .idle).insertIsFresh(now: now)) // no request at all
        #expect(hostState(phase: .idle, insertAt: now).insertIsFresh(now: now))
        #expect(hostState(phase: .idle, insertAt: now.addingTimeInterval(-LinkChannel.insertMaxAge + 0.1)).insertIsFresh(now: now))
        #expect(!hostState(phase: .idle, insertAt: now.addingTimeInterval(-LinkChannel.insertMaxAge - 0.1)).insertIsFresh(now: now))
    }

    @Test func theBoundaryMatchesTheMicKeysFreshness() {
        let edge = hostState(phase: .listening, beatAt: now.addingTimeInterval(-LinkChannel.beatFreshness))
        #expect(!edge.isLive(now: now))
        #expect(MicKeyMode.resolve(host: edge, now: now, fullAccess: true) == .openApp) // same verdict
    }

    // MARK: Meeting notice

    private func recording(_ state: HostState) -> HostState {
        var copy = state
        copy.meetingRecording = true
        return copy
    }

    @Test func aFreshMeetingFlagMakesTheKeyboardSayWhy() {
        let state = recording(hostState(phase: .idle, beatAt: now.addingTimeInterval(-1)))
        #expect(state.meetingNotice(now: now) == "Meeting recording")
    }

    @Test func aMeetingFlagWithAStaleBeatIsADeadApp() {
        // The app died mid-meeting and left the flag behind: do not keep blocking the keyboard.
        let state = recording(hostState(phase: .idle, beatAt: now.addingTimeInterval(-LinkChannel.beatFreshness - 0.1)))
        #expect(state.meetingNotice(now: now) == nil)
        let edge = recording(hostState(phase: .idle, beatAt: now.addingTimeInterval(-LinkChannel.beatFreshness)))
        #expect(edge.meetingNotice(now: now) == nil)
    }

    @Test func noMeetingFlagNoNotice() {
        #expect(hostState(phase: .idle, beatAt: now).meetingNotice(now: now) == nil)
        var cleared = recording(hostState(phase: .idle, beatAt: now))
        cleared.meetingRecording = false
        #expect(cleared.meetingNotice(now: now) == nil)
    }
}
