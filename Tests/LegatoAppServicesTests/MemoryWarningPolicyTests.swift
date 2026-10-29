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

    /// A load the warmup itself started (keyboard arm, refine, un-awaited) is not cancelled by a low warning.
    @Test func aWarmupStartedLoadIsNotCancelledByALowWarningAndTheReleaseWaitsForItsEnd() async throws {
        final class Gate: @unchecked Sendable {
            let lock = NSLock(); var open = false; var cancelled = false
        }
        let gate = Gate(), warmup = SelectedModelWarmup()
        let started = AsyncStream<Void>.makeStream()
        let settled = AsyncStream<Void>.makeStream()
        let resource = SelectedModelWarmup.Resource(key: "cleanup:local", prewarm: {
            started.1.yield(())
            while !gate.lock.withLock({ gate.open }) {
                if Task.isCancelled { gate.lock.withLock { gate.cancelled = true }; throw CancellationError() }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }, release: {})
        await warmup.onLoadsSettled { settled.1.yield(()) }
        await warmup.setRequested([resource], for: .refine, inBackground: false)
        var it = started.0.makeAsyncIterator(); _ = await it.next()
        #expect(await warmup.hasLoadsInFlight)

        var released = 0
        let policy = MemoryWarningPolicy(
            availableMemory: { MemoryWarningPolicy.floorBytes - 1 },
            isLoading: { await warmup.hasLoadsInFlight },
            release: { released += 1; await warmup.invalidate() },
            log: { _ in })
        await policy.handleWarning()
        #expect(released == 0)
        #expect(!gate.lock.withLock { gate.cancelled })

        gate.lock.withLock { gate.open = true }
        var s = settled.0.makeAsyncIterator(); _ = await s.next()
        #expect(!(await warmup.hasLoadsInFlight))
        await policy.loadFinished()
        #expect(released == 1)
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
