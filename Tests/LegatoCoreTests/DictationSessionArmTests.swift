import Foundation
import Testing
@testable import LegatoCore

/// A lease armed without a run: the mic and audio session are ready, nothing is transcribed.
@MainActor
@Suite struct DictationSessionArmTests {
    @Test func armingActivatesTheAudioSessionAndMicButStartsNoRun() async throws {
        let r = Rig(linger: .seconds(60))
        try await r.session.armLease()
        #expect(r.session.leaseState == .armed)
        #expect(r.session.runState == .idle)
        #expect(r.log.events == ["engine.prepare", "activate", "source.start", "source.detach"])
        #expect(r.session.editCount == 0)
        #expect(await r.history.entries.isEmpty)
    }

    @Test func anAlreadyCancelledArmNeverActivatesMicrophone() async throws {
        let r = Rig(linger: .seconds(60))
        let arming = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await r.session.armLease()
        }
        await #expect(throws: CancellationError.self) { try await arming.value }
        #expect(r.log.count("activate") == 0)
        #expect(r.log.count("source.start") == 0)
        #expect(r.session.leaseState == .idle)
    }

    @Test func theNextRunReusesTheArmedLeaseWithoutActivatingAgain() async throws {
        let r = Rig(linger: .seconds(60))
        try await r.session.armLease()
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(r.log.count("activate") == 1 && r.log.count("source.start") == 1)
        #expect(r.log.count("source.route") == 1)
        #expect(r.session.leaseState == .armed) // the linger keeps it after the run
    }

    @Test func anArmedLeaseExpiresAfterItsLingerAndSaysSo() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .seconds(60), sleep: clock.sleep)
        var expired = 0
        r.session.onLeaseExpired = { expired += 1 }
        try await r.session.armLease()
        #expect(await eventually { clock.requested == [.seconds(60)] })
        clock.advance(by: .seconds(59))
        await Task.yield()
        #expect(r.session.leaseState == .armed)
        clock.advance(by: .seconds(1))
        #expect(await eventually { r.session.leaseState == .idle })
        #expect(r.log.count("deactivate") == 1 && r.log.count("source.stop") == 1)
        #expect(expired == 1)
    }

    @Test func anIndefiniteArmedLeaseHasNoTimer() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .indefinite, sleep: clock.sleep)
        try await r.session.armLease()
        #expect(clock.requested.isEmpty)
        #expect(r.session.leaseState == .armed)
    }

    @Test func aFailedArmTearsTheLeaseDownAndThrows() async throws {
        let r = Rig(linger: .seconds(60))
        r.source.failStart(with: TestError())
        await #expect(throws: TestError.self) { try await r.session.armLease() }
        #expect(r.session.leaseState == .idle)
        #expect(r.log.count("deactivate") == 1)
    }

    @Test func armingWithoutTheSpeechModelThrowsBeforeTouchingAudio() async throws {
        let r = Rig(linger: .seconds(60))
        r.engine.set(installed: false)
        await #expect(throws: DictationError.assetsNotInstalled) { try await r.session.armLease() }
        #expect(r.log.count("activate") == 0)
        #expect(r.session.leaseState == .idle)
    }

    @Test func armingDuringARunIsRefused() async throws {
        let r = Rig(linger: .seconds(60))
        try await r.session.start()
        await #expect(throws: DictationError.alreadyRunning) { try await r.session.armLease() }
        _ = try await r.session.stop()
    }

    @Test func armingAnAlreadyArmedLeaseRestartsItsTimerWithoutActivatingAgain() async throws {
        let clock = VirtualClock()
        let r = Rig(linger: .seconds(60), sleep: clock.sleep)
        try await r.session.armLease()
        #expect(await eventually { clock.requested.count == 1 })
        clock.advance(by: .seconds(40))
        try await r.session.armLease()
        #expect(await eventually { clock.requested.count == 2 })
        #expect(r.log.count("activate") == 1)
        clock.advance(by: .seconds(59)) // 99 s in, 59 s after the second arm
        await Task.yield()
        #expect(r.session.leaseState == .armed)
        clock.advance(by: .seconds(1))
        #expect(await eventually { r.session.leaseState == .idle })
        #expect(r.log.count("deactivate") == 1)
    }

    // MARK: adopting the linger of the run that reuses the lease

    @Test func aLingerAdoptedForTheNextRunLeavesTheHeldLeaseAloneUntilTheRunEnds() async throws {
        let r = Rig(linger: .seconds(60))
        try await r.session.armLease()
        r.session.adoptLinger(.off)
        #expect(r.session.linger == .off)
        #expect(r.session.leaseState == .armed) // setLinger(.off) would have released it here
        #expect(r.log.count("deactivate") == 0)
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(r.session.leaseState == .idle) // the run's own linger: released when it ends
        #expect(r.log.count("deactivate") == 1)
    }
}
