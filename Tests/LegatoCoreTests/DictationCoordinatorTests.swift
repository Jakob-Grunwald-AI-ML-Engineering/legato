import Foundation
import Synchronization
import Testing
@testable import LegatoCore

/// A settable "now" shared by the session and the coordinator.
final class TestTime: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// The durations the coordinator asked its injected sleep for.
final class SleepLog: Sendable {
    private let store = Mutex<[Duration]>([])
    func add(_ d: Duration) { store.withLock { $0.append(d) } }
    var durations: [Duration] { store.withLock { $0 } }
}

/// Whether the coordinator's settle wait blocks until the rig's `settleClock` ticks.
final class SettleGate: Sendable {
    private let flag = Mutex(false)
    var held: Bool { flag.withLock { $0 } }
    func hold(_ on: Bool) { flag.withLock { $0 = on } }
}

/// Set when an awaited call returned; lets a test observe that something is still waiting.
@MainActor
final class Done {
    var value = false
}

/// The sessions the factory built, in order.
@MainActor
final class BuiltSessions {
    var all: [DictationSession] = []
    /// The linger the factory was asked for, per session.
    var lingers: [Linger] = []
    /// The audio policy each session in `all` was built for.
    var policies: [AudioPolicy] = []
}

@MainActor
struct CoordinatorRig {
    typealias Outcome = DictationCoordinator.Outcome

    let log = EventLog()
    let engine: FakeEngine
    let source: FakeSource
    let control: FakeSessionControl
    let history = MemoryHistory()
    let activity: FakeActivity
    let clipboard: FakeClipboard
    let readiness = FakeReadiness()
    let environment = FakeStartEnvironment()
    let heartbeat = ManualClock()
    /// Drives the trailing publish: every injected sleep that is not the heartbeat's.
    let throttle = ManualClock()
    let time = TestTime()
    let sleeps = SleepLog()
    let built = BuiltSessions()
    /// Drives the sessions' keep-alive window: one tick expires one lingering lease.
    let lingerClock = ManualClock()
    /// The settle wait before a foreground retry: instant unless `holdSettle` is on, then one tick ends it.
    let settleClock = ManualClock()
    let settleGate = SettleGate()
    /// Not attached to the coordinator unless a test calls `attachSink()`.
    let sink: FakeSink
    let coordinator: DictationCoordinator

    /// `wrapControl`: the session control the sessions get, built around the rig's fake (default: the fake).
    init(script: [TranscriptEvent] = [], wrapControl: ((FakeSessionControl) -> any AudioSessionControlling)? = nil) {
        let log = self.log, history = self.history, time = self.time, built = self.built
        let heartbeat = self.heartbeat, throttle = self.throttle, sleeps = self.sleeps
        let lingerClock = self.lingerClock, settleClock = self.settleClock, settleGate = self.settleGate
        let engine = FakeEngine(log: log)
        engine.set(script: script)
        let source = FakeSource(log: log)
        let control = FakeSessionControl(log: log)
        let sessionControl: any AudioSessionControlling = wrapControl?(control) ?? control
        let activity = FakeActivity(log: log)
        let clipboard = FakeClipboard(log: log)
        sink = FakeSink(log: log)
        self.engine = engine
        self.source = source
        self.control = control
        self.activity = activity
        self.clipboard = clipboard
        coordinator = DictationCoordinator(
            activity: activity, clipboard: clipboard, readiness: readiness, startEnvironment: environment,
            history: history, makeSession: { policy, linger in
                let session = DictationSession(
                    engine: engine, source: source, sessionControl: sessionControl, history: history,
                    policy: policy, linger: linger, sleep: lingerClock.sleep, now: { time.now }
                )
                built.all.append(session)
                built.lingers.append(linger)
                built.policies.append(policy)
                return session
            },
            sleep: { duration in
                sleeps.add(duration)
                if duration == DictationCoordinator.settleDelay { // settle waits don't block tests, unless held
                    if settleGate.held { try await settleClock.sleep(duration) }
                    return
                }
                if duration == .seconds(10) { // the heartbeat
                    try await heartbeat.sleep(duration)
                } else {
                    try await throttle.sleep(duration)
                }
            },
            now: { time.now }
        )
        coordinator.onIdle = { log.add("idle") }
        coordinator.onStartFallback = { from, to, _ in log.add("fallback:\(from.rawValue)>\(to.rawValue)") }
    }

    func attachSink() { coordinator.sink = sink }

    /// Phases in order with consecutive repeats collapsed (listening updates come and go with edits).
    var phaseTrail: [DictationPhase] {
        var out: [DictationPhase] = []
        for p in activity.phases where p != out.last { out.append(p) }
        return out
    }
}

@MainActor
@Suite struct DictationCoordinatorTests {
    typealias Outcome = DictationCoordinator.Outcome

    // MARK: start

    @Test func activityIsRequestedBeforeTheSessionStartsThenGoesListening() async throws {
        let r = CoordinatorRig()
        #expect(await r.coordinator.toggle() == .started)
        let ev = r.log.events
        let request = try #require(ev.firstIndex(of: "activity.request:starting"))
        let prepare = try #require(ev.firstIndex(of: "engine.prepare"))
        let listening = try #require(ev.firstIndex(of: "activity.update:listening"))
        #expect(request < prepare && prepare < listening)
        #expect(r.phaseTrail == [.starting, .listening])
        #expect(r.activity.calls.first?.content.startedAt == r.time.now)
        _ = await r.coordinator.toggle()
    }

    @Test(arguments: ReadinessIssue.allCases)
    func notReadyNeedsOnboardingWithNoActivityAndNoAudio(issue: ReadinessIssue) async throws {
        let r = CoordinatorRig()
        r.readiness.issue = issue
        #expect(await r.coordinator.toggle() == .needsOnboarding(issue))
        #expect(r.log.events.isEmpty) // no activity, no engine, no audio, no idle hook
        #expect(r.built.all.isEmpty)
        // Once the app fixed it, the next press starts normally.
        r.readiness.issue = nil
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    // MARK: foreground hop

    private let backgroundWithMusic = StartContext(inBackground: true, otherAudioPlaying: true)
    private let foregroundWithMusic = StartContext(inBackground: false, otherAudioPlaying: true)

    @Test func backgroundStartWithOtherAudioIsAttemptedAndSucceeds() async throws {
        let r = CoordinatorRig(script: [TranscriptEvent(text: "hello ", isFinal: true)])
        r.environment.context = backgroundWithMusic
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.built.all.count == 1)
        #expect(r.phaseTrail == [.starting, .listening])
        #expect(await r.coordinator.toggle() == .stopped("hello"))
        #expect(r.clipboard.written == ["hello"])
        #expect(r.phaseTrail.last == .copied)
    }

    @Test func refusedBackgroundStartWithOtherAudioDismissesAndNeedsTheForeground() async throws {
        let r = CoordinatorRig(script: [TranscriptEvent(text: "hello ", isFinal: true)])
        r.environment.context = backgroundWithMusic
        r.source.failStart(with: TestError(tag: "refused"))
        #expect(await r.coordinator.toggle() == .needsForeground(.backgroundStartRefused))
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 1)
        #expect(r.activity.ends.isEmpty)
        #expect(r.log.count("idle") == 0)
        r.source.clearStartFailure()
        r.environment.context = foregroundWithMusic
        #expect(await r.coordinator.toggle() == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello"))
    }

    @Test func foregroundStartWithOtherAudioJustStarts() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundWithMusic
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    @Test func backgroundStartWithoutOtherAudioJustStarts() async throws {
        let r = CoordinatorRig()
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false)
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    // MARK: policy fallback

    private let backgroundExperimental = StartContext(
        inBackground: true, otherAudioPlaying: true, audioPolicy: .duckMusicPauseSpoken)

    @Test(arguments: ["activation", "source"])
    func aRefusedExperimentalPolicyFallsBackToDuckOthersInTheBackground(failingStep: String) async throws {
        let r = CoordinatorRig(script: [TranscriptEvent(text: "hello ", isFinal: true)])
        r.environment.context = backgroundExperimental
        if failingStep == "activation" {
            r.control.failActivation(with: TestError(tag: "refused"), only: [.duckMusicPauseSpoken])
        } else {
            r.source.failNextStarts(1, with: TestError(tag: "refused"))
        }
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckOthers])
        #expect(r.control.activatedConfigs.last == AudioPolicy.duckOthers.sessionConfig)
        #expect(r.log.count("fallback:duckMusicPauseSpoken>duckOthers") == 1)
        // The one activity stays: not dismissed, not requested again, never shown as failed.
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.activity.ends.isEmpty)
        #expect(r.log.count("idle") == 0)
        #expect(r.phaseTrail == [.starting, .listening])
        // The session that was refused is torn down (mic stopped, audio session deactivated) before the
        // retry is announced, and the retry activates only after that.
        let ev = r.log.events
        let refusedTeardown = try #require(ev.firstIndex(of: "deactivate"))
        let fallback = try #require(ev.firstIndex(of: "fallback:duckMusicPauseSpoken>duckOthers"))
        #expect(try #require(ev.firstIndex(of: "source.stop")) < refusedTeardown)
        #expect(refusedTeardown < fallback && fallback < ev.lastIndex(of: "activate")!)
        #expect(r.log.count("deactivate") == 1) // the retry's session is still live
        #expect(await r.coordinator.toggle() == .stopped("hello"))
        #expect(r.clipboard.written == ["hello"])
        #expect(await r.history.entries.count == 1)
        #expect(r.log.count("idle") == 1)
        #expect(r.phaseTrail.last == .copied)
        #expect(r.activity.ends.count == 1)
    }

    @Test func whenTheFallbackIsRefusedTooTheHopHappensOnce() async throws {
        let r = CoordinatorRig()
        r.environment.context = backgroundExperimental
        r.control.failActivation(with: TestError(tag: "refused"))
        #expect(await r.coordinator.toggle() == .needsForeground(.backgroundStartRefused))
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckOthers]) // one retry, not a loop
        #expect(r.log.count("fallback:duckMusicPauseSpoken>duckOthers") == 1)
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 1)
        #expect(r.activity.ends.isEmpty)
        #expect(r.log.count("idle") == 0)
        // The foreground press starts under the selected policy again.
        r.control.clearActivationFailure()
        r.environment.context = StartContext(inBackground: false, otherAudioPlaying: true, audioPolicy: .duckMusicPauseSpoken)
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.policies.last == .duckMusicPauseSpoken)
        _ = await r.coordinator.toggle()
    }

    @Test func aRefusedDefaultPolicyHopsAtOnceWithoutARetry() async throws {
        let r = CoordinatorRig()
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: true, audioPolicy: .duckOthers)
        r.control.failActivation(with: TestError(tag: "refused"))
        #expect(await r.coordinator.toggle() == .needsForeground(.backgroundStartRefused))
        #expect(r.built.policies == [.duckOthers])
        #expect(r.log.count("fallback:duckOthers>duckOthers") == 0)
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
        #expect(r.log.count("activity.dismiss") == 1)
    }

    @Test(arguments: [AudioPolicy.mixWithOthers, .pauseOthers])
    func anyNonDefaultPolicyFallsBackToDuckOthers(policy: AudioPolicy) async throws {
        let r = CoordinatorRig()
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false, audioPolicy: policy)
        r.control.failActivation(with: TestError(tag: "refused"), only: [policy])
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.policies == [policy, .duckOthers])
        _ = await r.coordinator.toggle()
    }

    @Test func aRefusalInTheForegroundNeverFallsBack() async throws {
        let r = CoordinatorRig()
        r.environment.context = StartContext(inBackground: false, otherAudioPlaying: true, audioPolicy: .duckMusicPauseSpoken)
        r.control.failActivation(with: TestError(tag: "refused"))
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckMusicPauseSpoken])
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
    }

    @Test func aNonRefusalErrorInTheBackgroundNeverFallsBack() async throws {
        let r = CoordinatorRig()
        r.environment.context = backgroundExperimental
        r.engine.set(prepareError: TestError(tag: "prep"))
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckMusicPauseSpoken])
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
        #expect(r.phaseTrail == [.starting, .failed])
    }

    @Test func aFallbackThatFailsForAnotherReasonEndsTheActivityFailedOnce() async throws {
        let r = CoordinatorRig()
        r.environment.context = backgroundExperimental
        r.control.failActivation(with: TestError(tag: "refused"), only: [.duckMusicPauseSpoken])
        r.source.failStart(with: TestError(tag: "mic")) // not a refusal: reached only by the retry
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckOthers])
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.activity.ends.count == 1)
        #expect(r.log.count("idle") == 1)
    }

    // MARK: foreground: the mic had no input yet

    private let foregroundDefault = StartContext(inBackground: false, otherAudioPlaying: false, audioPolicy: .duckOthers)
    private let foregroundExperimental = StartContext(
        inBackground: false, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)
    private let notReady = TestError(tag: "notReady")

    @Test func aForegroundStartWithoutMicInputRetriesOnceAfterTheSettleDelay() async throws {
        let r = CoordinatorRig(script: [TranscriptEvent(text: "hello ", isFinal: true)])
        r.environment.context = foregroundDefault
        r.source.failNextStarts(1, with: notReady)
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.policies == [.duckOthers, .duckOthers]) // a fresh session, same policy
        #expect(r.sleeps.durations.filter { $0 == DictationCoordinator.settleDelay }.count == 1)
        #expect(r.log.count("fallback:duckOthers>duckOthers") == 1)
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.activity.ends.isEmpty)
        #expect(r.log.count("idle") == 0)
        #expect(r.phaseTrail == [.starting, .listening])
        // The first session is torn down before the settle wait; the second starts after it.
        let ev = r.log.events
        let tornDown = try #require(ev.firstIndex(of: "deactivate"))
        let retry = try #require(ev.firstIndex(of: "fallback:duckOthers>duckOthers"))
        #expect(try #require(ev.firstIndex(of: "source.stop")) < tornDown)
        #expect(tornDown < retry && retry < ev.lastIndex(of: "activate")!)
        #expect(retry < ev.lastIndex(of: "engine.transcribe")!)
        #expect(r.log.count("deactivate") == 1)
        #expect(await r.coordinator.toggle() == .stopped("hello"))
        #expect(r.log.count("idle") == 1)
    }

    @Test func aForegroundStartThatNeverGetsMicInputFailsAfterOneRetry() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundDefault
        r.source.failStart(with: notReady)
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckOthers, .duckOthers]) // once, not a loop
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.activity.ends.count == 1)
        #expect(r.log.count("idle") == 1)
        // Not wedged.
        r.source.clearStartFailure()
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    @Test func aNonDefaultPolicyRetriesTheSamePolicyThenDuckOthers() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundExperimental
        r.source.failNextStarts(2, with: notReady)
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckMusicPauseSpoken, .duckOthers])
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }
            == ["fallback:duckMusicPauseSpoken>duckMusicPauseSpoken", "fallback:duckMusicPauseSpoken>duckOthers"])
        #expect(r.sleeps.durations.filter { $0 == DictationCoordinator.settleDelay }.count == 2)
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 0)
        _ = await r.coordinator.toggle()
    }

    @Test func aNonDefaultPolicyThatKeepsFailingEndsFailedAfterThreeAttempts() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundExperimental
        r.source.failStart(with: notReady)
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckMusicPauseSpoken, .duckOthers])
        #expect(r.activity.ends.count == 1)
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.log.count("idle") == 1)
    }

    @Test func otherForegroundRefusalsStillFailWithoutARetry() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundExperimental
        r.control.failActivation(with: TestError(tag: "refused"))
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.built.policies == [.duckMusicPauseSpoken])
        #expect(!r.sleeps.durations.contains(DictationCoordinator.settleDelay))
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
    }

    @Test func inTheBackgroundNoMicInputKeepsTheImmediateFallbackAndHop() async throws {
        let r = CoordinatorRig()
        r.environment.context = backgroundExperimental
        r.source.failStart(with: notReady)
        #expect(await r.coordinator.toggle() == .needsForeground(.backgroundStartRefused))
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckOthers]) // no same-policy retry here
        #expect(!r.sleeps.durations.contains(DictationCoordinator.settleDelay))
        #expect(r.log.count("activity.dismiss") == 1)
    }

    @Test func missingSetupOutranksAnyStartAttempt() async throws {
        let r = CoordinatorRig()
        r.environment.context = backgroundWithMusic
        r.readiness.issue = .micPermission
        #expect(await r.coordinator.toggle() == .needsOnboarding(.micPermission))
    }

    @Test(arguments: ["activation", "source"])
    func aRefusedBackgroundStartLeavesNoActivityAndNoAudioAndRetriesInTheForeground(failingStep: String) async throws {
        let r = CoordinatorRig(script: [TranscriptEvent(text: "hello ", isFinal: true)])
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false)
        if failingStep == "activation" {
            r.control.failActivation(with: TestError(tag: "refused"))
        } else {
            r.source.failStart(with: TestError(tag: "refused"))
        }
        #expect(await r.coordinator.toggle() == .needsForeground(.backgroundStartRefused))
        // The activity that came first is gone at once, not ended `failed`; the run never counted.
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("activity.dismiss") == 1)
        #expect(r.activity.ends.isEmpty)
        #expect(r.log.count("idle") == 0)
        #expect(r.clipboard.written.isEmpty)
        #expect(await r.history.entries.isEmpty)
        #expect(r.log.count("engine.transcribe") == 0)
        let ev = r.log.events
        let dismissed = try #require(ev.firstIndex(of: "activity.dismiss"))
        #expect(try #require(ev.firstIndex(of: "activity.request:starting")) < dismissed)

        // The foreground press: not wedged, a fresh session, one clipboard write, one history entry.
        r.control.clearActivationFailure()
        r.source.clearStartFailure()
        r.environment.context = StartContext(inBackground: false, otherAudioPlaying: false)
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.all.count == 2)
        #expect(r.log.count("activity.request:starting") == 2)
        #expect(await r.coordinator.toggle() == .stopped("hello"))
        #expect(r.clipboard.written == ["hello"])
        #expect(await r.history.entries.count == 1)
        #expect(r.log.count("idle") == 1)
        #expect(r.phaseTrail.last == .copied)
    }

    @Test func aRefusalShapedErrorInTheForegroundIsAPlainFailure() async throws {
        let r = CoordinatorRig()
        r.environment.context = foregroundWithMusic
        r.control.failActivation(with: TestError(tag: "refused"))
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.phaseTrail == [.starting, .failed])
    }

    @Test func anyOtherErrorInTheBackgroundIsAPlainFailure() async throws {
        let r = CoordinatorRig()
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false)
        r.engine.set(prepareError: TestError(tag: "prep"))
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.log.count("idle") == 1)
    }

    @Test func refusedActivityNeedsOnboardingAndNeverStartsAudio() async throws {
        let r = CoordinatorRig()
        r.activity.requestError = TestError(tag: "activities")
        #expect(await r.coordinator.toggle() == .needsOnboarding(.liveActivitiesDisabled))
        #expect(r.log.count("engine.prepare") == 0)
        #expect(r.built.all.isEmpty)
        #expect(r.activity.ends.isEmpty)
    }

    @Test func startFailureEndsTheActivityFailed() async throws {
        let r = CoordinatorRig()
        r.engine.set(prepareError: TestError(tag: "prep"))
        guard case .failed = await r.coordinator.toggle() else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.activity.ends.count == 1)
        #expect(r.log.count("activate") == 0)
        let ev = r.log.events
        #expect(try #require(ev.firstIndex(of: "activity.end:failed")) < ev.firstIndex(of: "idle")!)
        // Not wedged: the next press builds a fresh session.
        r.engine.clearPrepareError()
        #expect(await r.coordinator.toggle() == .started)
    }

    @Test func missingAssetsAtStartEndTheActivityAndAskForOnboarding() async throws {
        let r = CoordinatorRig()
        r.engine.set(installed: false)
        #expect(await r.coordinator.toggle() == .needsOnboarding(.assetsMissing))
        #expect(r.phaseTrail == [.starting, .failed])
    }

    @Test func pressWhileStartingGoesThroughSessionStopAndEndsTheActivity() async throws {
        let r = CoordinatorRig()
        r.engine.set(hangInPrepare: true)
        let first = Task { await r.coordinator.toggle() }
        #expect(await eventually { r.built.all.first?.runState == .preparing })
        #expect(await r.coordinator.toggle() == .stopped(nil))
        #expect(await first.value == .stopped(nil))
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.activity.ends.count == 1) // no phantom activity, none ended twice
        #expect(r.log.count("activate") == 0)
        #expect(r.log.count("idle") == 1)
        // Back to idle: a later press starts again.
        r.engine.set(hangInPrepare: false)
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    @Test func pressWhileTheActivityIsBeingRequestedNeverStartsAudio() async throws {
        let r = CoordinatorRig()
        r.activity.holdRequest = true
        let first = Task { await r.coordinator.toggle() }
        #expect(await eventually { r.log.count("activity.request:starting") == 1 })
        #expect(await r.coordinator.toggle() == .stopped(nil))
        r.activity.holdRequest = false
        #expect(await first.value == .stopped(nil))
        #expect(r.log.count("engine.prepare") == 0)
        #expect(r.built.all.isEmpty)
        #expect(r.phaseTrail == [.starting, .failed])
        #expect(r.activity.ends.count == 1)
    }

    // MARK: stop

    @Test func stopCopiesTheEntryTextAndEndsCopied() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle() == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.clipboard.written == ["hello world"])
        #expect(await r.history.entries.map(\.text) == ["hello world"]) // the session's append, not doubled
        let end = try #require(r.activity.ends.first)
        #expect(r.activity.ends.count == 1)
        #expect(end.phase == .copied && end.tail == "hello world")
        #expect(r.phaseTrail == [.starting, .listening, .finishing, .copied])
        let ev = r.log.events
        #expect(try #require(ev.firstIndex(of: "clipboard.write")) < ev.firstIndex(of: "activity.end:copied")!)
    }

    @Test func clipboardThatDidNotChangeEndsTapToCopy() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.clipboard.changes = false
        _ = await r.coordinator.toggle()
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        let end = try #require(r.activity.ends.first)
        #expect(end.phase == .tapToCopy && end.tail == "hello world")
    }

    @Test func stopWithNothingRecognizedEndsFailedAndLeavesTheClipboard() async throws {
        let r = CoordinatorRig(script: [.init(text: "um", isFinal: false)])
        _ = await r.coordinator.toggle()
        #expect(await r.coordinator.toggle() == .stopped(nil))
        #expect(r.clipboard.written.isEmpty)
        #expect(r.activity.ends.map(\.phase) == [.failed])
        #expect(await r.history.entries.isEmpty)
    }

    @Test func finalStateUsesTheEntryTextNotTheThrottledBuffer() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle()
        r.time.advance(1)
        r.engine.emit(.init(text: "hello", isFinal: true), run: 0)
        #expect(await eventually { r.activity.updates.last?.content.tail == "hello" })
        r.engine.emit(.init(text: " world", isFinal: true), run: 0) // inside the window: not published
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.updates.last?.content.tail == "hello")
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.activity.ends.first?.tail == "hello world")
    }

    @Test func eachStartBuildsAFreshSession() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        for _ in 0..<2 {
            #expect(await r.coordinator.toggle() == .started)
            #expect(await r.coordinator.toggle() == .stopped("hello world"))
        }
        #expect(r.built.all.count == 2)
        #expect(r.built.all.count == 2 && r.built.all.first !== r.built.all.last)
        #expect(await r.history.entries.count == 2)
        #expect(r.activity.ends.count == 2)
    }

    // MARK: abort

    @Test func abortCopiesCommittedTextAppendsHistoryOnceAndEndsTheActivity() async throws {
        let r = CoordinatorRig(script: [
            .init(text: "partial text", isFinal: true), .init(text: "tentative", isFinal: false),
        ])
        r.engine.set(streamError: TestError(tag: "stream"))
        _ = await r.coordinator.toggle()
        #expect(await eventually { !r.activity.ends.isEmpty })
        #expect(await eventually { r.log.count("idle") == 1 })
        #expect(r.clipboard.written == ["partial text"]) // committed only, no volatile tail
        #expect(await r.history.entries.map(\.text) == ["partial text"])
        #expect(r.activity.ends.map(\.phase) == [.copied])
        #expect(r.activity.ends.first?.tail == "partial text")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await r.history.entries.count == 1) // still once
        #expect(r.log.count("idle") == 1)
    }

    @Test func nextStartAfterAnAbortBuildsAFreshSession() async throws {
        let r = CoordinatorRig(script: [.init(text: "partial text", isFinal: true)])
        r.engine.set(streamError: TestError(tag: "stream"))
        _ = await r.coordinator.toggle()
        #expect(await eventually { r.log.count("idle") == 1 })
        r.engine.clearStreamError()
        #expect(await r.coordinator.toggle() == .started) // a start, not a stop of the dead session
        #expect(r.built.all.count == 2)
        #expect(await r.coordinator.toggle() == .stopped("partial text"))
    }

    @Test func abortWithoutCommittedTextEndsFailed() async throws {
        let r = CoordinatorRig(script: [.init(text: "tentative", isFinal: false)])
        r.engine.set(streamError: TestError(tag: "stream"))
        _ = await r.coordinator.toggle()
        #expect(await eventually { r.log.count("idle") == 1 })
        #expect(r.activity.ends.map(\.phase) == [.failed])
        #expect(r.clipboard.written.isEmpty)
        #expect(await r.history.entries.isEmpty)
    }

    @Test func stopThatFailsSalvagesTheCommittedText() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.engine.set(finishError: TestError(tag: "fin"))
        _ = await r.coordinator.toggle()
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.clipboard.written == ["hello world"])
        #expect(await r.history.entries.map(\.text) == ["hello world"]) // stop() threw before saving: once
        #expect(r.activity.ends.map(\.phase) == [.copied])
        #expect(r.log.count("idle") == 1)
    }

    // MARK: live updates

    @Test func editsReachTheActivityAtMostOncePerSecond() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle()
        r.time.advance(1)
        r.engine.emit(.init(text: "hello", isFinal: false), run: 0)
        #expect(await eventually { r.activity.updates.last?.content.tail == "hello" })
        let published = r.activity.updates.count
        r.engine.emit(.init(text: "hello wor", isFinal: false), run: 0) // same instant: held back
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.updates.count == published)
        r.time.advance(1)
        r.engine.emit(.init(text: "hello world", isFinal: false), run: 0)
        #expect(await eventually { r.activity.updates.last?.content.tail == "hello world" })
        #expect(r.activity.updates.count == published + 1)
        #expect(r.activity.updates.allSatisfy { $0.content.phase == .listening })
        _ = await r.coordinator.toggle()
    }

    @Test func aThrottledEditIsPublishedWhenTheWindowEnds() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle() // first publish at T
        let published = r.activity.updates.count
        r.time.advance(0.4)
        r.engine.emit(.init(text: "hello", isFinal: false), run: 0) // inside the window, then silence
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.updates.count == published) // never faster than once a second
        r.time.advance(0.6) // the window ends at T + 1 s
        r.throttle.tick()
        #expect(await eventually { r.activity.updates.last?.content.tail == "hello" })
        #expect(r.activity.updates.count == published + 1)
        #expect(r.activity.updates.last?.staleDate == r.time.now.addingTimeInterval(30))
        _ = await r.coordinator.toggle()
    }

    @Test func theTrailingPublishWaitsOutTheRestOfTheWindowAndCarriesTheLatestTail() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle()
        let published = r.activity.updates.count
        r.time.advance(0.4)
        r.engine.emit(.init(text: "hello", isFinal: false), run: 0)
        r.engine.emit(.init(text: "hello wor", isFinal: false), run: 0)
        #expect(await eventually {
            r.sleeps.durations.contains { $0 > .milliseconds(590) && $0 < .milliseconds(610) }
        })
        r.time.advance(0.1)
        r.engine.emit(.init(text: "hello world", isFinal: false), run: 0)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.updates.count == published) // one pending publish, not one per edit
        r.time.advance(0.5)
        r.throttle.tick()
        #expect(await eventually { r.activity.updates.last?.content.tail == "hello world" })
        #expect(r.activity.updates.count == published + 1)
        _ = await r.coordinator.toggle()
    }

    @Test func aPublishThatIsDueSupersedesThePendingTrailingOne() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle()
        let published = r.activity.updates.count
        r.time.advance(0.4)
        r.engine.emit(.init(text: "hello", isFinal: false), run: 0) // held back; trailing pending
        try? await Task.sleep(for: .milliseconds(50))
        r.time.advance(0.7)
        r.engine.emit(.init(text: "hello world", isFinal: false), run: 0) // window over: published now
        #expect(await eventually { r.activity.updates.last?.content.tail == "hello world" })
        r.throttle.tick() // the superseded trailing publish must not add a duplicate
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.updates.count == published + 1)
        _ = await r.coordinator.toggle()
    }

    @Test func stoppingCancelsThePendingTrailingPublish() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle()
        r.time.advance(0.4)
        r.engine.emit(.init(text: "hello", isFinal: true), run: 0)
        try? await Task.sleep(for: .milliseconds(50))
        _ = await r.coordinator.toggle()
        let after = r.activity.calls.count
        r.time.advance(1)
        r.throttle.tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.calls.count == after)
        #expect(r.activity.ends.first?.phase == .copied)
    }

    @Test func heartbeatRefreshesTheStaleDateWhileListening() async throws {
        let r = CoordinatorRig()
        _ = await r.coordinator.toggle()
        let before = r.activity.updates.count
        r.time.advance(5)
        r.heartbeat.tick()
        #expect(await eventually { r.activity.updates.count == before + 1 })
        let beat = try #require(r.activity.updates.last)
        #expect(beat.content.phase == .listening)
        #expect(beat.staleDate == r.time.now.addingTimeInterval(30))
        r.time.advance(10)
        r.heartbeat.tick()
        #expect(await eventually { r.activity.updates.count == before + 2 })
        #expect(r.activity.updates.last?.staleDate == r.time.now.addingTimeInterval(30))
        #expect(r.sleeps.durations.allSatisfy { $0 == .seconds(10) })

        // It stops with the run.
        _ = await r.coordinator.toggle()
        let after = r.activity.calls.count
        r.heartbeat.tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.activity.calls.count == after)
    }

    // MARK: system stop

    @Test func aSystemStopAfterAFinishedStopNeverStartsADictation() async throws {
        // Our own setActive(false) on stop raises a route change with no inputs; the app's handler then
        // asks for a stop while the coordinator is already idle. It must not start a new run.
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle() == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(await r.coordinator.stopIfRunning() == nil)
        #expect(r.built.all.count == 1)
        #expect(r.log.count("activity.request:starting") == 1)
        #expect(r.log.count("engine.prepare") == 1)
        #expect(r.log.count("idle") == 1)
        // Still idle and usable: the next press starts.
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    @Test func aSystemStopWhileListeningStopsAndCopies() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle() == .started)
        #expect(await r.coordinator.stopIfRunning() == .stopped("hello world"))
        #expect(r.clipboard.written == ["hello world"])
        #expect(await r.history.entries.map(\.text) == ["hello world"])
        #expect(r.activity.ends.map(\.phase) == [.copied])
        #expect(r.log.count("idle") == 1)
        // A second system event for the same loss is a no-op.
        #expect(await r.coordinator.stopIfRunning() == nil)
        #expect(r.built.all.count == 1)
    }

    @Test func aSystemStopWhileIdleDoesNothing() async throws {
        let r = CoordinatorRig()
        #expect(await r.coordinator.stopIfRunning() == nil)
        #expect(r.log.events.isEmpty)
        #expect(r.built.all.isEmpty)
    }

    @Test func aSystemStopWhileStartingCancelsTheStart() async throws {
        let r = CoordinatorRig()
        r.engine.set(hangInPrepare: true)
        let first = Task { await r.coordinator.toggle() }
        #expect(await eventually { r.built.all.first?.runState == .preparing })
        #expect(await r.coordinator.stopIfRunning() == .stopped(nil))
        #expect(await first.value == .stopped(nil))
        #expect(r.log.count("activate") == 0)
        #expect(r.built.all.count == 1) // cancelled, not restarted
        #expect(r.activity.ends.count == 1)
    }

    @Test func aSystemStopWhileStoppingIsIgnored() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        _ = await r.coordinator.toggle()
        r.engine.set(holdFinish: true) // the session's stop hangs inside the engine's finish
        let stopping = Task { await r.coordinator.toggle() }
        #expect(await eventually { r.log.count("engine.finish") == 1 }) // the coordinator is in .stopping now
        #expect(r.coordinator.isIdle == false)
        #expect(await r.coordinator.stopIfRunning() == nil) // ignored while the stop is wrapping up
        #expect(await r.coordinator.stopIfRunning(releasingLease: true) == nil)
        #expect(r.log.count("engine.finish") == 1 && r.log.count("idle") == 0) // and it changed nothing
        r.engine.set(holdFinish: false)
        #expect(await stopping.value == .stopped("hello world"))
        #expect(r.built.all.count == 1)
        #expect(r.log.count("idle") == 1)
        #expect(r.clipboard.written == ["hello world"])
    }

    // MARK: idle hook

    @Test func idleHookFiresOnlyAfterTheActivityEnded() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        _ = await r.coordinator.toggle()
        #expect(r.log.count("idle") == 0) // listening is not idle
        _ = await r.coordinator.toggle()
        let ev = r.log.events
        #expect(r.log.count("idle") == 1)
        #expect(try #require(ev.firstIndex(of: "activity.end:copied")) < ev.firstIndex(of: "idle")!)
        #expect(ev.last == "idle")
    }
}
