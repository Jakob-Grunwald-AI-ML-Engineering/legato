import Testing
@testable import LegatoMac

@Suite struct MeetingMicRouteTests {
    private let me: Int32 = 100
    private let teams: Int32 = 200
    private let browser: Int32 = 300
    private let builtIn: UInt32 = 92
    private let airPods: UInt32 = 122

    private func call(_ pid: Int32, on devices: [UInt32]) -> AutoMuteProcess {
        AutoMuteProcess(pid: pid, isRunningInput: true, isRunningOutput: true, inputDevices: devices)
    }

    /// The field case: Teams records from the built-in mic while the AirPods are the default input.
    @Test func followsTheCallAppsInputNotTheDefault() {
        let choice = MeetingMicRoute.choose(
            processes: [call(teams, on: [builtIn])], ownPID: me, defaultInput: airPods)
        #expect(choice == MeetingMicChoice(device: builtIn, followsCall: true))
        #expect(choice.pinned == builtIn)
    }

    @Test func ourOwnProcessIsNeverTheCallApp() {
        let choice = MeetingMicRoute.choose(
            processes: [call(me, on: [airPods]), call(teams, on: [builtIn])], ownPID: me, defaultInput: airPods)
        #expect(choice.device == builtIn)

        let alone = MeetingMicRoute.choose(processes: [call(me, on: [builtIn])], ownPID: me, defaultInput: airPods)
        #expect(alone == MeetingMicChoice(device: airPods, followsCall: false))
    }

    @Test func withoutACallAppItIsTheDefaultInput() {
        let choice = MeetingMicRoute.choose(processes: [], ownPID: me, defaultInput: airPods)
        #expect(choice == MeetingMicChoice(device: airPods, followsCall: false))
        #expect(choice.pinned == nil, "the mic stays on the default and follows it")
    }

    @Test func aCallAppWithNoInputDeviceFallsBackToTheDefault() {
        let choice = MeetingMicRoute.choose(processes: [call(teams, on: [])], ownPID: me, defaultInput: airPods)
        #expect(choice == MeetingMicChoice(device: airPods, followsCall: false))
    }

    @Test func aProcessThatOnlyRecordsIsNotACallApp() {
        let mic = AutoMuteProcess(pid: browser, isRunningInput: true, isRunningOutput: false, inputDevices: [builtIn])
        let choice = MeetingMicRoute.choose(processes: [mic], ownPID: me, defaultInput: airPods)
        #expect(choice == MeetingMicChoice(device: airPods, followsCall: false))
    }

    @Test func explicitInputWinsOverTheCallAndDefault() {
        let choice = MeetingMicRoute.choose(
            processes: [call(teams, on: [airPods])], ownPID: me, defaultInput: airPods, selectedInput: builtIn)
        #expect(choice.device == builtIn)
        #expect(choice.pinned == builtIn)
    }

    @Test func noDefaultAndNoCallAppIsNoDevice() {
        #expect(MeetingMicRoute.choose(processes: [], ownPID: me, defaultInput: nil) == MeetingMicChoice(device: nil, followsCall: false))
    }
}
