import Foundation
import Testing
@testable import LegatoAppServices

private actor Releases {
    private(set) var count = 0
    func released() { count += 1 }
}

private struct Unavailable: Error {}

private func lease(_ model: String, _ releases: Releases) -> CleanupRunLease {
    CleanupRunLease(
        resolution: .init(choice: .coreML(modelID: model), backend: nil, skipped: [], execution: nil),
        release: { await releases.released() })
}

/// The stateless final pass of a run whose cleanup agent was absent takes the same lease a run takes at its start:
/// the admitted backend (a bridge included) is held for the pass, then released.
@Suite(.timeLimit(.minutes(1))) struct LeasedCleanupTests {
    @Test func thePassRunsOnTheLeasedResolutionAndReleasesItAfterwards() async {
        let releases = Releases()
        let seen = Releases()
        let out = await LeasedCleanup.run(acquire: { lease("bridge", releases) }, within: .seconds(5)) { resolution in
            #expect(resolution?.choice == .coreML(modelID: "bridge"))
            #expect(await releases.count == 0)  // held while the pass runs
            await seen.released()
            return "cleaned"
        }
        #expect(out == "cleaned")
        #expect(await seen.count == 1)
        #expect(await releases.count == 1)
    }

    @Test func aFailedAcquireRunsNoPass() async {
        let ran = Releases()
        let out = await LeasedCleanup.run(acquire: { throw Unavailable() }, within: .seconds(5)) { _ in
            await ran.released()
            return "cleaned"
        }
        #expect(out == nil)
        #expect(await ran.count == 0)
    }

    @Test func anAcquireStillWaitingPastTheLimitIsGivenUpAndItsLateLeaseReleased() async {
        let releases = Releases(), ran = Releases()
        let out = await LeasedCleanup.run(
            acquire: {
                try await Task.sleep(for: .milliseconds(300))  // a Core ML load still warming
                return lease("late", releases)
            }, within: .milliseconds(30)
        ) { _ in
            await ran.released()
            return "cleaned"
        }
        #expect(out == nil)
        #expect(await ran.count == 0)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await releases.count == 1)
    }
}
