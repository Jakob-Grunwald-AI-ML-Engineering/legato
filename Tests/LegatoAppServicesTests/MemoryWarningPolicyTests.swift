import Foundation
import Testing
@testable import LegatoAppServices

@MainActor private final class PolicyProbe {
    var available: UInt64 = 3_000_000_000
    var loading = false
    var releases = 0
    var logs: [String] = []
    lazy var policy = MemoryWarningPolicy(
        availableMemory: { [unowned self] in available },
        isLoading: { [unowned self] in loading },
        release: { [unowned self] in releases += 1 },
        log: { [unowned self] in logs.append($0) })
}

@Suite(.timeLimit(.minutes(1)))
@MainActor struct MemoryWarningPolicyTests {
    private let mb: UInt64 = 1_048_576

    @Test func aWarningAboveTheFloorKeepsTheModels() async {
        let probe = PolicyProbe()
        probe.available = MemoryWarningPolicy.floorBytes + mb
        await probe.policy.handleWarning()
        #expect(probe.releases == 0)
    }

    @Test func aWarningBelowTheFloorReleases() async {
        let probe = PolicyProbe()
        probe.available = MemoryWarningPolicy.floorBytes - mb
        await probe.policy.handleWarning()
        #expect(probe.releases == 1)
    }

    @Test func aWarningDuringALoadNeverReleasesAboveTheFloorAndLeavesNothingPending() async {
        let probe = PolicyProbe()
        probe.loading = true
        await probe.policy.handleWarning()
        probe.loading = false
        await probe.policy.loadFinished()
        #expect(probe.releases == 0)
    }

    @Test func aWarningDuringALoadBelowTheFloorWaitsForTheLoadThenReleasesIfStillLow() async {
        let probe = PolicyProbe()
        probe.available = MemoryWarningPolicy.floorBytes - mb
        probe.loading = true
        await probe.policy.handleWarning()
        #expect(probe.releases == 0)
        probe.loading = false
        await probe.policy.loadFinished()
        #expect(probe.releases == 1)
    }

    @Test func aDeferredReleaseIsDroppedWhenMemoryRecoveredAfterTheLoad() async {
        let probe = PolicyProbe()
        probe.available = MemoryWarningPolicy.floorBytes - mb
        probe.loading = true
        await probe.policy.handleWarning()
        probe.available = MemoryWarningPolicy.floorBytes + 100 * mb
        probe.loading = false
        await probe.policy.loadFinished()
        #expect(probe.releases == 0)
        #expect(probe.logs.last?.hasSuffix("action=kept") == true)
    }

    @Test func aFinishedLoadWithoutAWarningDoesNothing() async {
        let probe = PolicyProbe()
        probe.available = 1
        await probe.policy.loadFinished()
        #expect(probe.releases == 0)
        #expect(probe.logs.isEmpty)
    }

    @Test func everyWarningLogsAvailableMegabytesAndTheDecision() async {
        let probe = PolicyProbe()
        probe.available = 2048 * mb
        await probe.policy.handleWarning()
        probe.available = 100 * mb
        await probe.policy.handleWarning()
        #expect(probe.logs == ["memory.warning available=2048 action=kept", "memory.warning available=100 action=released"])
    }
}
