import Testing
@testable import LegatoMac

@Suite struct CallDetectionPolicyTests {
    private let me: Int32 = 100
    private let zoom: Int32 = 200
    private let browser: Int32 = 300

    private func policy() -> CallDetectionPolicy { CallDetectionPolicy(ownPID: me, ownBundlePrefix: "de.gruenwald.legato") }
    private func call(_ pid: Int32, _ bundle: String = "us.zoom.xos") -> AutoMuteProcess {
        AutoMuteProcess(pid: pid, bundleID: bundle, isRunningInput: true, isRunningOutput: true)
    }
    private func input(_ pid: Int32) -> AutoMuteProcess { AutoMuteProcess(pid: pid, isRunningInput: true, isRunningOutput: false) }
    private func playing(_ pid: Int32) -> AutoMuteProcess { AutoMuteProcess(pid: pid, isRunningInput: false, isRunningOutput: true) }

    private func tick(_ p: inout CallDetectionPolicy, _ processes: [AutoMuteProcess], at t: Double, dictating: Bool = false, meeting: Bool = false)
        -> CallDetectionPolicy.Event? {
        p.update(processes: processes, dictationBusy: dictating, meetingActive: meeting, at: t)
    }

    @Test func aCallBeginsOnceItHasLastedThroughTheDebounce() {
        var p = policy()
        #expect(tick(&p, [call(zoom)], at: 0) == nil)
        #expect(tick(&p, [call(zoom)], at: 2) == nil)
        #expect(tick(&p, [call(zoom)], at: 3) == .began(.init(pid: zoom, bundleID: "us.zoom.xos")))
    }

    @Test func aBlipNeverFiresAndRestartsTheDebounce() {
        var p = policy()
        #expect(tick(&p, [call(zoom)], at: 0) == nil)
        #expect(tick(&p, [], at: 1) == nil)
        #expect(tick(&p, [call(zoom)], at: 2) == nil)
        #expect(tick(&p, [call(zoom)], at: 4) == nil, "two seconds into the second sighting")
        #expect(tick(&p, [call(zoom)], at: 5) != nil)
    }

    @Test func ourOwnProcessAndBundleAreNotCalls() {
        var p = policy()
        #expect(tick(&p, [call(me, "de.gruenwald.legato.mac")], at: 0) == nil)
        #expect(tick(&p, [call(me, "de.gruenwald.legato.mac")], at: 5) == nil)
        #expect(tick(&p, [call(999, "de.gruenwald.legato.mac.helper")], at: 6) == nil)
        #expect(tick(&p, [call(999, "de.gruenwald.legato.mac.helper")], at: 12) == nil)
    }

    @Test func inputOnlyOrOutputOnlyIsNotACall() {
        var p = policy()
        #expect(tick(&p, [input(browser), playing(zoom)], at: 0) == nil)
        #expect(tick(&p, [input(browser), playing(zoom)], at: 10) == nil)
    }

    @Test func theSameCallPromptsOnlyOnceEvenWhenItGoesOnLong() {
        var p = policy()
        _ = tick(&p, [call(zoom)], at: 0)
        #expect(tick(&p, [call(zoom)], at: 3) != nil)
        for t in stride(from: 4.0, through: 120, by: 1) { #expect(tick(&p, [call(zoom)], at: t) == nil) }
    }

    @Test func aMuteThatClosesTheMicDoesNotEndTheCallButLeavingDoes() {
        var p = policy()
        _ = tick(&p, [call(zoom)], at: 0)
        _ = tick(&p, [call(zoom)], at: 3)
        #expect(tick(&p, [playing(zoom)], at: 4) == nil, "muted: the app still plays")
        #expect(tick(&p, [], at: 20) == nil, "gone, grace starts")
        #expect(tick(&p, [call(zoom)], at: 25) == nil, "back within the grace: still the same call")
        #expect(tick(&p, [], at: 30) == nil)
        #expect(tick(&p, [], at: 39) == nil)
        #expect(tick(&p, [], at: 40) == .ended)
    }

    @Test func aNewCallAfterTheEndPromptsAgain() {
        var p = policy()
        _ = tick(&p, [call(zoom)], at: 0)
        _ = tick(&p, [call(zoom)], at: 3)
        _ = tick(&p, [], at: 5)
        #expect(tick(&p, [], at: 15) == .ended)
        #expect(tick(&p, [call(zoom)], at: 20) == nil)
        #expect(tick(&p, [call(zoom)], at: 23) != nil)
    }

    @Test func nothingFiresWhileDictatingAndTheDebounceStartsAfter() {
        var p = policy()
        #expect(tick(&p, [call(zoom)], at: 0, dictating: true) == nil)
        #expect(tick(&p, [call(zoom)], at: 10, dictating: true) == nil)
        #expect(tick(&p, [call(zoom)], at: 11) == nil)
        #expect(tick(&p, [call(zoom)], at: 14) != nil)
    }

    @Test func aCallSeenDuringAMeetingIsHandledAndNeverPromptsAfterwards() {
        var p = policy()
        #expect(tick(&p, [call(zoom)], at: 0, meeting: true) == nil)
        #expect(tick(&p, [call(zoom)], at: 10, meeting: true) == nil)
        #expect(tick(&p, [call(zoom)], at: 20) == nil, "the meeting stopped, the call goes on")
        #expect(tick(&p, [call(zoom)], at: 40) == nil)
    }

    @Test func aCallEndStopsAMeetingOnlyThatStartedAutomatically() {
        #expect(CallDetectionPolicy.Event.ended.stopsMeeting(startedAutomatically: true))
        #expect(!CallDetectionPolicy.Event.ended.stopsMeeting(startedAutomatically: false))
        #expect(!CallDetectionPolicy.Event.began(.init(pid: 1, bundleID: "")).stopsMeeting(startedAutomatically: true))
    }
}
