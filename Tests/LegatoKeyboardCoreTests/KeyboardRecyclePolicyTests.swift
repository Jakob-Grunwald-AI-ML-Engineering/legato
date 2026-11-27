import Testing
@testable import LegatoKeyboardCore

@Suite struct KeyboardRecyclePolicyTests {
    private let policy = KeyboardRecyclePolicy()

    /// A healthy, hidden, idle, old process whose host session has ended.
    private func facts(_ change: (inout KeyboardRecyclePolicy.Facts) -> Void = { _ in }) -> KeyboardRecyclePolicy.Facts {
        var facts = KeyboardRecyclePolicy.Facts(sessionEnded: true, visible: 0, hiddenControllers: 1, owesWork: false,
                                                uptimeSeconds: 600, previewBlanks: 0, memoryWarnings: 0)
        change(&facts)
        return facts
    }

    @Test func healthyProcessStays() {
        #expect(policy.decide(facts()) == .healthy)
        #expect(policy.decide(facts { $0.hiddenControllers = policy.maxHiddenControllers }) == .healthy)
        // Keyboards hidden during the session are still alive as the host leaves: 3 was measured in ordinary use.
        #expect(policy.decide(facts { $0.hiddenControllers = 3 }) == .healthy)
    }

    @Test func eachSignalRecyclesOnceTheSessionHasEnded() {
        #expect(policy.decide(facts { $0.previewBlanks = 1 }) == .recycle(.previewBlank))
        #expect(policy.decide(facts { $0.hiddenControllers = policy.maxHiddenControllers + 1 }) == .recycle(.leakedControllers))
        #expect(policy.decide(facts { $0.memoryWarnings = 1 }) == .recycle(.memoryWarning))
    }

    /// Ending the process under a host still holding it makes iOS fall back to Apple's keyboard on the next show.
    @Test func neverExitsWhileTheSessionIsOpen() {
        #expect(policy.decide(facts { $0.previewBlanks = 1; $0.sessionEnded = false }) == .wait(.previewBlank, .sessionOpen))
        #expect(policy.decide(facts { $0.forced = true; $0.sessionEnded = false }) == .wait(.forced, .sessionOpen))
    }

    @Test func neverExitsWhileVisibleOrOwingWork() {
        let unhealthy = facts { $0.hiddenControllers = 7 }
        #expect(policy.decide(facts { $0 = unhealthy; $0.visible = 1 }) == .wait(.leakedControllers, .visible))
        #expect(policy.decide(facts { $0 = unhealthy; $0.visible = 1; $0.owesWork = true }) == .wait(.leakedControllers, .visible))
        #expect(policy.decide(facts { $0 = unhealthy; $0.owesWork = true }) == .wait(.leakedControllers, .owesWork))
    }

    @Test func aYoungProcessIsKeptUnlessForced() {
        #expect(policy.decide(facts { $0.memoryWarnings = 1; $0.uptimeSeconds = policy.minimumUptimeSeconds - 1 })
                == .wait(.memoryWarning, .young))
        #expect(policy.decide(facts { $0.forced = true; $0.uptimeSeconds = 1 }) == .recycle(.forced))
    }
}
