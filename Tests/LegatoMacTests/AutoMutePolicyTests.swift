import Testing
@testable import LegatoMac

@Suite struct AutoMutePolicyTests {
    private let me: Int32 = 100
    private let zoom: Int32 = 200
    private let browser: Int32 = 300

    private func input(_ pid: Int32) -> AutoMuteProcess { AutoMuteProcess(pid: pid, isRunningInput: true, isRunningOutput: false) }
    private func call(_ pid: Int32) -> AutoMuteProcess { AutoMuteProcess(pid: pid, isRunningInput: true, isRunningOutput: true) }
    private func playing(_ pid: Int32) -> AutoMuteProcess { AutoMuteProcess(pid: pid, isRunningInput: false, isRunningOutput: true) }

    @Test func neverMutesWithoutACallAppHavingBeenSeen() {
        var p = AutoMutePolicy(ownPID: me)
        #expect(p.update(systemAudioActive: true, processes: []) == false)
        #expect(p.update(systemAudioActive: true, processes: [call(me)]) == false)
        #expect(p.update(systemAudioActive: true, processes: []) == false)
    }

    @Test func mutesWhenTheCallAppReleasesTheMicAndUnmutesWhenItReturns() {
        var p = AutoMutePolicy(ownPID: me)
        #expect(p.update(systemAudioActive: true, processes: [call(me), call(zoom)]) == false)
        #expect(p.update(systemAudioActive: true, processes: [call(me), playing(zoom)]) == true)
        #expect(p.update(systemAudioActive: true, processes: [call(me), call(zoom)]) == false)
    }

    @Test func aBrowserMicCheckThatOnlyTakesInputNeverArms() {
        var p = AutoMutePolicy(ownPID: me)
        // A web page testing the mic takes input but plays nothing: not a call app.
        #expect(p.update(systemAudioActive: true, processes: [input(browser)]) == false)
        #expect(p.update(systemAudioActive: true, processes: []) == false)
    }

    @Test func onlyTheCallAppsReleaseMutesAndOtherProcessesDoNotCountEitherWay() {
        var p = AutoMutePolicy(ownPID: me)
        #expect(p.update(systemAudioActive: true, processes: [call(zoom), input(browser)]) == false)
        // Zoom releases while the browser still holds the mic: Zoom's release is what counts.
        #expect(p.update(systemAudioActive: true, processes: [playing(zoom), input(browser)]) == true)
        // The browser letting go changes nothing.
        #expect(p.update(systemAudioActive: true, processes: [playing(zoom)]) == true)
        // A process that merely takes the mic does not unmute.
        #expect(p.update(systemAudioActive: true, processes: [playing(zoom), input(browser)]) == true)
        #expect(p.update(systemAudioActive: true, processes: [call(zoom)]) == false)
    }

    @Test func withTwoCallAppsItMutesOnlyWhenNoneHoldsTheMic() {
        var p = AutoMutePolicy(ownPID: me)
        _ = p.update(systemAudioActive: true, processes: [call(zoom), call(browser)])
        #expect(p.update(systemAudioActive: true, processes: [playing(zoom), call(browser)]) == false)
        #expect(p.update(systemAudioActive: true, processes: [playing(zoom), playing(browser)]) == true)
    }

    @Test func ownPIDIsIgnored() {
        var p = AutoMutePolicy(ownPID: me)
        // Only our own mic is open: that is not a call app, so it never arms the policy.
        _ = p.update(systemAudioActive: true, processes: [call(me)])
        #expect(p.update(systemAudioActive: true, processes: []) == false)
    }

    @Test func inactiveSystemAudioNeverMutesNorArms() {
        var p = AutoMutePolicy(ownPID: me)
        _ = p.update(systemAudioActive: true, processes: [call(zoom)])
        #expect(p.update(systemAudioActive: false, processes: []) == false)

        var q = AutoMutePolicy(ownPID: me)
        _ = q.update(systemAudioActive: false, processes: [call(zoom)])
        #expect(q.update(systemAudioActive: true, processes: []) == false)
    }
}
