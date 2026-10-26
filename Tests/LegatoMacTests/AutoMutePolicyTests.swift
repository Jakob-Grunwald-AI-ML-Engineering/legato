import Testing
@testable import LegatoMac

@Suite struct AutoMutePolicyTests {
    private let me: Int32 = 100
    private let zoom: Int32 = 200

    @Test func neverMutesWithoutACallAppHavingBeenSeen() {
        var p = AutoMutePolicy(ownPID: me)
        #expect(p.update(systemAudioActive: true, inputPIDs: [], manuallyMuted: false) == false)
        #expect(p.update(systemAudioActive: true, inputPIDs: [me], manuallyMuted: false) == false)
        #expect(p.update(systemAudioActive: true, inputPIDs: [], manuallyMuted: false) == false)
    }

    @Test func mutesWhenTheCallAppReleasesTheMicAndUnmutesWhenItReturns() {
        var p = AutoMutePolicy(ownPID: me)
        #expect(p.update(systemAudioActive: true, inputPIDs: [me, zoom], manuallyMuted: false) == false)
        #expect(p.update(systemAudioActive: true, inputPIDs: [me], manuallyMuted: false) == true)
        #expect(p.update(systemAudioActive: true, inputPIDs: [me, zoom], manuallyMuted: false) == false)
    }

    @Test func manualMuteWins() {
        var p = AutoMutePolicy(ownPID: me)
        _ = p.update(systemAudioActive: true, inputPIDs: [zoom], manuallyMuted: false)
        #expect(p.update(systemAudioActive: true, inputPIDs: [], manuallyMuted: true) == false)
        #expect(p.update(systemAudioActive: true, inputPIDs: [], manuallyMuted: false) == true)
    }

    @Test func ownPIDIsIgnored() {
        var p = AutoMutePolicy(ownPID: me)
        // Only our own mic is open: that is not a call app, so it never arms the policy.
        _ = p.update(systemAudioActive: true, inputPIDs: [me], manuallyMuted: false)
        #expect(p.update(systemAudioActive: true, inputPIDs: [], manuallyMuted: false) == false)
    }

    @Test func inactiveSystemAudioNeverMutes() {
        var p = AutoMutePolicy(ownPID: me)
        _ = p.update(systemAudioActive: true, inputPIDs: [zoom], manuallyMuted: false)
        #expect(p.update(systemAudioActive: false, inputPIDs: [], manuallyMuted: false) == false)
    }
}
