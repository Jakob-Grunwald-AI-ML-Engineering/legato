import Foundation
import Testing
@testable import LegatoCore

/// The lease's linger: every run restarts the whole timer, no expiry at all for `.indefinite`, and a
/// linger changed while the lease is held.
@MainActor
@Suite struct DictationSessionLingerTests {
    private func run(_ r: Rig) async throws {
        try await r.session.start()
        _ = try await r.session.stop()
    }

    // MARK: every run restarts the full timer

    @Test func aRunAtTimeXKeepsTheLeaseUntilItsOwnEndPlusLingerNotTheFirstEndPlusLinger() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .seconds(30), sleep: clock.sleep)
        try await run(r) // ends at t = 0: expiry would be t = 30
        #expect(await eventually { clock.requested.count == 1 }) // the timer is armed before time moves
        clock.advance(by: .seconds(20))
        try await run(r) // a second run, ends at t = 20: expiry is now t = 50
        #expect(await eventually { clock.requested.count == 2 })
        #expect(clock.requested == [.seconds(30), .seconds(30)]) // the whole linger again, not the 10 s left

        clock.advance(by: .seconds(20)) // t = 40: past the first run's expiry
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.session.leaseState == .armed)
        #expect(r.log.count("deactivate") == 0)

        clock.advance(by: .seconds(9)) // t = 49
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.session.leaseState == .armed)

        clock.advance(by: .seconds(1)) // t = 50: the second run's expiry
        #expect(await eventually { r.session.leaseState == .idle })
        #expect(r.log.count("deactivate") == 1)
    }

    // MARK: indefinite

    @Test func anIndefiniteLeaseSchedulesNoTimerAndOutlivesAnyWait() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .indefinite, sleep: clock.sleep)
        try await run(r)
        #expect(clock.requested.isEmpty)
        clock.advance(by: .seconds(100_000))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.session.leaseState == .armed)
        #expect(r.log.count("deactivate") == 0)

        try await run(r) // reused
        #expect(r.log.count("activate") == 1 && r.log.count("source.route") == 1)
        #expect(clock.requested.isEmpty)
    }

    @Test func anIndefiniteLeaseEndsOnEndLease() async throws {
        let r = Rig(linger: .indefinite)
        try await run(r)
        await r.session.endLease()
        #expect(r.session.leaseState == .idle)
        #expect(r.log.count("deactivate") == 1)
    }

    @Test func anIndefiniteLeaseDoesNotFireTheExpiryHook() async throws {
        let r = Rig(linger: .indefinite)
        var fired = 0
        r.session.onLeaseExpired = { fired += 1 }
        try await run(r)
        await r.session.endLease()
        #expect(fired == 0)
    }

    // MARK: a linger changed while the lease is held

    @Test func aShorterLingerRearmsTheFullNewTimerFromNow() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .seconds(600), sleep: clock.sleep)
        try await run(r)
        #expect(await eventually { clock.requested.count == 1 })
        clock.advance(by: .seconds(100))
        await r.session.setLinger(.seconds(60))
        #expect(r.session.linger == .seconds(60))
        #expect(await eventually { clock.requested.count == 2 })
        #expect(clock.requested == [.seconds(600), .seconds(60)])
        clock.advance(by: .seconds(59))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.session.leaseState == .armed)
        clock.advance(by: .seconds(1))
        #expect(await eventually { r.session.leaseState == .idle })
    }

    @Test func aLingerOfOffReleasesAHeldLeaseAtOnce() async throws {
        let r = Rig(linger: .seconds(600))
        try await run(r)
        await r.session.setLinger(.off)
        #expect(r.session.leaseState == .idle)
        #expect(r.log.count("deactivate") == 1)
    }

    @Test func anIndefiniteLingerCancelsTheRunningTimer() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .seconds(60), sleep: clock.sleep)
        try await run(r)
        #expect(await eventually { clock.requested.count == 1 })
        await r.session.setLinger(.indefinite)
        clock.advance(by: .seconds(10_000))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.session.leaseState == .armed)
        #expect(r.log.count("deactivate") == 0)
    }

    @Test func aLingerChangedDuringARunAppliesWhenItEnds() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .seconds(60), sleep: clock.sleep)
        try await r.session.start()
        await r.session.setLinger(.seconds(300))
        #expect(clock.requested.isEmpty)
        _ = try await r.session.stop()
        #expect(await eventually { clock.requested == [.seconds(300)] })
    }
}
