import Testing
@testable import LegatoKeyboardCore

@Suite struct KeyboardRecyclePolicyTests {
    private let policy = KeyboardRecyclePolicy()

    /// A hidden, idle, settled, old process using a modest share of its limit.
    private func facts(_ change: (inout KeyboardRecyclePolicy.Facts) -> Void = { _ in }) -> KeyboardRecyclePolicy.Facts {
        var facts = KeyboardRecyclePolicy.Facts(visible: 0, hiddenControllers: 0, owesWork: false, quietSeconds: 10, uptimeSeconds: 600,
                                                footprintBytes: 80_000_000, availableBytes: 100_000_000, previewBlanks: 0, memoryWarnings: 0)
        change(&facts)
        return facts
    }

    @Test func healthyProcessStays() {
        #expect(policy.decide(facts()) == .healthy)
        #expect(policy.decide(facts { $0.hiddenControllers = policy.maxHiddenControllers }) == .healthy)
    }

    @Test func eachSignalRecyclesAnIdleHiddenProcess() {
        #expect(policy.decide(facts { $0.previewBlanks = 1 }) == .recycle(.previewBlank))
        #expect(policy.decide(facts { $0.hiddenControllers = policy.maxHiddenControllers + 1 }) == .recycle(.leakedControllers))
        #expect(policy.decide(facts { $0.memoryWarnings = 1 }) == .recycle(.memoryWarning))
        #expect(policy.decide(facts { $0.footprintBytes = 150_000_000; $0.availableBytes = 40_000_000 }) == .recycle(.memoryFootprint))
    }

    @Test func neverExitsWhileVisibleOrOwingWork() {
        let unhealthy = facts { $0.hiddenControllers = 7 }
        #expect(policy.decide(facts { $0 = unhealthy; $0.visible = 1 }) == .wait(.leakedControllers, .visible))
        #expect(policy.decide(facts { $0 = unhealthy; $0.visible = 1; $0.owesWork = true }) == .wait(.leakedControllers, .visible))
        #expect(policy.decide(facts { $0 = unhealthy; $0.owesWork = true }) == .wait(.leakedControllers, .owesWork))
    }

    @Test func waitsForTheHideToSettleAndForAMinimumUptime() {
        let unhealthy = facts { $0.memoryWarnings = 1 }
        #expect(policy.decide(facts { $0 = unhealthy; $0.quietSeconds = policy.settleSeconds - 0.1 }) == .wait(.memoryWarning, .settling))
        #expect(policy.decide(facts { $0 = unhealthy; $0.uptimeSeconds = policy.minimumUptimeSeconds - 1 }) == .wait(.memoryWarning, .young))
    }

    @Test func unknownFootprintIsNotASignal() {
        #expect(policy.decide(facts { $0.footprintBytes = nil; $0.availableBytes = 0 }) == .healthy)
    }
}
