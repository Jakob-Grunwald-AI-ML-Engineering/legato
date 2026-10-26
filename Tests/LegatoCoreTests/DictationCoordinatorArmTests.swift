import Foundation
import Testing
@testable import LegatoCore

/// Arming the microphone without a run: the keyboard's first tap hops to the app, which only readies the
/// mic lease; the next tap (back in the host app) starts dictation on that lease.
@MainActor
@Suite struct DictationCoordinatorArmTests {
    typealias Armed = DictationCoordinator.ArmOutcome

    static let keyboard = StartOptions(keepAlive: .off, target: .keyboard)

    private let backgroundExperimental = StartContext(
        inBackground: true, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)
    private let foregroundExperimental = StartContext(
        inBackground: false, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)

    // MARK: the lease length

    @Test func theArmLeaseIsTheKeepReadySettingWhenItHoldsALease() {
        #expect(DictationCoordinator.armLinger(for: .seconds(300)) == .seconds(300))
        #expect(DictationCoordinator.armLinger(for: .seconds(1)) == .seconds(1))
        #expect(DictationCoordinator.armLinger(for: .indefinite) == .indefinite)
    }

    @Test func withKeepReadyOffTheArmLeaseIsASixtySecondFloor() {
        #expect(DictationCoordinator.armFloor == .seconds(60))
        #expect(DictationCoordinator.armLinger(for: .off) == .seconds(60))
    }

    // MARK: arming does nothing but ready the mic

    @Test func armingReadiesTheMicAndStartsNoRunNoActivityNoClipboardNoHistory() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(r.log.events == ["engine.prepare", "activate", "source.start", "source.detach", "sink.lease:set"])
        #expect(r.activity.calls.isEmpty)
        #expect(r.clipboard.written.isEmpty)
        #expect(await r.history.entries.isEmpty)
        #expect(r.sink.started.isEmpty && r.sink.ended.isEmpty && r.sink.updates.isEmpty)
        #expect(r.coordinator.holdsLease && r.coordinator.isIdle)
    }

    @Test func theFloorLeaseIsBuiltAndReportedForSixtySeconds() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(r.built.lingers == [.seconds(60)])
        #expect(r.sink.leases == [r.time.now.addingTimeInterval(60)])
    }

    @Test func theKeepReadySettingSetsTheArmLeaseWhenItIsOn() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        #expect(await r.coordinator.arm(keepAlive: .seconds(300)) == .armed)
        #expect(r.built.lingers == [.seconds(300)])
        #expect(r.sink.leases == [r.time.now.addingTimeInterval(300)])
    }

    @Test func anIndefiniteKeepReadyArmsALeaseWithNoEnd() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        #expect(await r.coordinator.arm(keepAlive: .indefinite) == .armed)
        #expect(r.sink.leases == [.distantFuture])
    }

    @Test func theFloorLeaseExpiresAfterSixtySecondsAndTheSinkHearsIt() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        _ = await r.coordinator.arm(keepAlive: .off)
        r.lingerClock.tick()
        #expect(await eventually { !r.coordinator.holdsLease })
        #expect(r.log.count("deactivate") == 1)
        #expect(r.sink.leases.map { $0 != nil } == [true, false])
    }

    @Test func armingNeverFiresTheIdleHook() async throws {
        let r = CoordinatorRig()
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(r.log.count("idle") == 0)
    }

    // MARK: the tap after returning

    @Test func theNextStartRunsOnTheArmedLeaseWithoutActivatingAgain() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false)
        _ = await r.coordinator.arm(keepAlive: .off)
        #expect(await r.coordinator.startIfIdle(Self.keyboard) == .started)
        #expect(r.built.all.count == 1) // the armed session: nothing new was built or activated
        #expect(r.log.count("activate") == 1 && r.log.count("source.start") == 1 && r.log.count("source.route") == 1)
        #expect(r.sink.started.map(\.target) == [.keyboard])
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    @Test func afterAnOffRunOnTheFloorLeaseTheMicIsReleasedAndTheSinkHearsIt() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        _ = await r.coordinator.arm(keepAlive: .off)
        #expect(await r.coordinator.startIfIdle(Self.keyboard) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(!r.coordinator.holdsLease)
        #expect(r.log.count("deactivate") == 1) // "then release"
        #expect(r.sink.leases.map { $0 != nil } == [true, false])
        // The next start after that has no lease to reuse.
        #expect(await r.coordinator.startIfIdle(Self.keyboard) == .started)
        #expect(r.built.all.count == 2)
        _ = await r.coordinator.toggle()
    }

    @Test func afterARunOnAnArmedLeaseWithKeepReadyOnTheLeaseIsKept() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        let options = StartOptions(keepAlive: .seconds(300), target: .keyboard)
        _ = await r.coordinator.arm(keepAlive: .seconds(300))
        #expect(await r.coordinator.startIfIdle(options) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.coordinator.holdsLease && r.log.count("deactivate") == 0)
        #expect(r.built.all.count == 1)
        #expect(r.sink.leases.last == .some(r.time.now.addingTimeInterval(300)))
    }

    @Test func aRunWithoutKeepReadyOnTheArmedFloorLeaseAlsoUsesIt() async throws {
        // The Action Button right after the keyboard armed the mic: same lease, then released (Off).
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(await r.coordinator.toggle(StartOptions()) == .started)
        #expect(r.built.all.count == 1 && r.log.count("activate") == 1)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.log.count("deactivate") == 1)
    }

    @Test func endKeepAliveReleasesAnArmedLease() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        _ = await r.coordinator.arm(keepAlive: .off)
        await r.coordinator.endKeepAlive()
        #expect(!r.coordinator.holdsLease)
        #expect(r.log.count("deactivate") == 1)
        #expect(r.sink.leases.map { $0 != nil } == [true, false])
    }

    @Test func armingAgainReplacesTheHeldLeaseWithAFreshOne() async throws {
        // The mic may have died under a held lease (the keyboard only hops after a failed remote start).
        let r = CoordinatorRig()
        _ = await r.coordinator.arm(keepAlive: .off)
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(r.built.all.count == 2)
        #expect(r.log.count("activate") == 2 && r.log.count("deactivate") == 1)
        #expect(r.coordinator.holdsLease)
    }

    // MARK: not while busy

    @Test func armingDuringARunDoesNothing() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        #expect(await r.coordinator.arm(keepAlive: .off) == .busy)
        #expect(r.built.all.count == 1)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    @Test func aPressWhileArmingIsBusyAndStartsNothing() async throws {
        let r = CoordinatorRig()
        r.engine.set(hangInPrepare: true)
        let arming = Task { await r.coordinator.arm(keepAlive: .off) }
        #expect(await eventually { r.log.count("engine.prepare") == 1 })
        #expect(await r.coordinator.toggle() == .busy)
        #expect(await r.coordinator.startIfIdle() == nil)
        #expect(await r.coordinator.stopIfRunning() == nil)
        r.engine.set(hangInPrepare: false)
        #expect(await arming.value == .armed)
        #expect(r.activity.calls.isEmpty)
    }

    // MARK: readiness and failures

    @Test(arguments: [ReadinessIssue.micPermission, .assetsMissing])
    func anUnreadyAppNeedsOnboardingAndArmsNothing(issue: ReadinessIssue) async throws {
        let r = CoordinatorRig()
        r.readiness.issue = issue
        #expect(await r.coordinator.arm(keepAlive: .off) == .needsOnboarding(issue))
        #expect(r.log.events.isEmpty && r.built.all.isEmpty)
        #expect(r.coordinator.isIdle)
    }

    @Test func disabledLiveActivitiesDoNotStopTheArmBecauseItHasNone() async throws {
        let r = CoordinatorRig()
        r.readiness.issue = .liveActivitiesDisabled
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
    }

    @Test func aMissingSpeechModelNeedsOnboarding() async throws {
        let r = CoordinatorRig()
        r.engine.set(installed: false)
        #expect(await r.coordinator.arm(keepAlive: .off) == .needsOnboarding(.assetsMissing))
        #expect(!r.coordinator.holdsLease && r.coordinator.isIdle)
    }

    @Test func aFailedArmReportsItLeavesNoLeaseAndReleasesTheCoordinator() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        r.source.failStart(with: TestError(tag: "boom"))
        guard case .failed = await r.coordinator.arm(keepAlive: .off) else {
            Issue.record("expected .failed")
            return
        }
        #expect(!r.coordinator.holdsLease && r.coordinator.isIdle)
        #expect(r.sink.leases.isEmpty)
        r.source.clearStartFailure()
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed) // the next try works
    }

    @Test func aRefusedBackgroundArmFallsBackToTheDefaultPolicy() async throws {
        let r = CoordinatorRig()
        r.environment.context = backgroundExperimental
        r.control.failActivation(with: TestError(tag: "refused"), only: [.duckMusicPauseSpoken])
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckOthers])
        #expect(r.built.lingers == [.seconds(60), .seconds(60)])
        #expect(r.log.events.contains("fallback:duckMusicPauseSpoken>duckOthers"))
    }

    @Test func aBackgroundArmTheSystemRefusesAnywayNeedsTheForeground() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        r.environment.context = backgroundExperimental
        r.control.failActivation(with: TestError(tag: "refused"))
        #expect(await r.coordinator.arm(keepAlive: .off) == .needsForeground(.backgroundStartRefused))
        #expect(!r.coordinator.holdsLease && r.coordinator.isIdle)
        #expect(r.sink.leases.isEmpty)
        #expect(r.activity.calls.isEmpty)
    }

    @Test func aMicWithoutInputYetIsRetriedInTheForeground() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundExperimental
        r.source.failNextStarts(2, with: TestError(tag: "notReady"))
        #expect(await r.coordinator.arm(keepAlive: .off) == .armed)
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckMusicPauseSpoken, .duckOthers])
        #expect(r.coordinator.holdsLease)
    }

    @Test func aMicThatNeverGetsInputFailsAfterTheRetries() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundExperimental
        r.source.failNextStarts(10, with: TestError(tag: "notReady"))
        guard case .failed = await r.coordinator.arm(keepAlive: .off) else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckMusicPauseSpoken, .duckOthers])
        #expect(!r.coordinator.holdsLease && r.coordinator.isIdle)
    }
}
