import Testing
@testable import LegatoMac

@Suite struct MeetingMuteStateTests {
    @Test func followsTheAutoDecisionWithoutAnOverride() {
        var s = MeetingMuteState()
        #expect(s.effective == false)
        s.setAuto(true)
        #expect(s.effective == true)
        s.setAuto(false)
        #expect(s.effective == false)
    }

    @Test func unmutingDuringAnAutoMuteWins() {
        var s = MeetingMuteState()
        s.setAuto(true)
        s.toggle()
        #expect(s.effective == false)
        // The same auto decision again does not take the override back.
        s.setAuto(true)
        #expect(s.effective == false)
    }

    @Test func mutingByHandWinsOverAutoUnmute() {
        var s = MeetingMuteState()
        s.toggle()
        #expect(s.effective == true)
        s.setAuto(false)
        #expect(s.effective == true)
    }

    @Test func theOverrideClearsWhenTheAutoDecisionNextChanges() {
        var s = MeetingMuteState()
        s.setAuto(true)
        s.toggle()                 // unmuted by hand during the auto-mute
        s.setAuto(false)           // the call app is back: auto follows again
        #expect(s.manualOverride == nil)
        #expect(s.effective == false)
        s.setAuto(true)
        #expect(s.effective == true)
    }

    @Test func toggleAlwaysFlipsTheEffectiveState() {
        var s = MeetingMuteState()
        s.setAuto(true)
        s.toggle(); #expect(s.effective == false)
        s.toggle(); #expect(s.effective == true)
    }
}
