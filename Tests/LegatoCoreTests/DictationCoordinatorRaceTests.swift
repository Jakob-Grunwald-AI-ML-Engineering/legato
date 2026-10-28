import Foundation
import Testing
@testable import LegatoCore

/// Presses and teardowns that overlap: a cancel while a refused start is torn down, a start while a
/// release is in flight, an abort that began before the start resumed. Every one is steered with a
/// held fake, so the interleaving is the test's, not the scheduler's.
@MainActor
@Suite struct DictationCoordinatorRaceTests {
    typealias Outcome = DictationCoordinator.Outcome

    static let keyboard = StartOptions(keepAlive: .seconds(30), target: .keyboard)
    private let background = StartContext(inBackground: true, otherAudioPlaying: false)
    private let foreground = StartContext(inBackground: false, otherAudioPlaying: false)
    private let notReady = TestError(tag: "notReady")

    private func runOnce(_ r: CoordinatorRig, _ options: StartOptions) async {
        #expect(await r.coordinator.toggle(options) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    // MARK: cancel during a refused start's teardown

    @Test func aCancelWhileARefusedStartIsTornDownStopsInsteadOfHopping() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        r.environment.context = background
        r.source.failStart(with: TestError(tag: "refused"))
        r.activity.holdDismiss = true
        let first = Task { await r.coordinator.toggle(Self.keyboard) }
        #expect(await eventually { r.log.count("activity.dismiss") == 1 }) // the refusal is being torn down
        #expect(await r.coordinator.toggle() == .stopped(nil)) // the user presses again
        r.activity.holdDismiss = false
        #expect(await first.value == .stopped(nil)) // no hop: the cancelled dictation must not start
        #expect(r.activity.ends.isEmpty) // dismissed, never shown as failed
        #expect(r.sink.started.count == 1 && r.sink.ended.count == 1) // the sink run is balanced
        #expect(r.coordinator.isIdle && !r.coordinator.holdsLease)
        #expect(r.log.count("idle") == 1) // nothing hops, so the app may go quiet
        // Not wedged: the next press starts.
        r.source.clearStartFailure()
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
    }

    @Test func aCancelDuringTheSettleWaitStopsWithoutAFailedActivityOrASecondSession() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        r.environment.context = foreground
        r.source.failNextStarts(1, with: notReady)
        r.settleGate.hold(true)
        let first = Task { await r.coordinator.toggle(Self.keyboard) }
        #expect(await eventually { r.sleeps.durations.contains(DictationCoordinator.settleDelay) }) // waiting to retry
        #expect(await r.coordinator.toggle() == .stopped(nil))
        r.settleClock.tick()
        #expect(await first.value == .stopped(nil))
        #expect(r.built.all.count == 1) // the retry never built a session
        #expect(r.log.count("activate") == 1) // and never activated audio again
        #expect(r.activity.ends.isEmpty && r.log.count("activity.dismiss") == 1)
        #expect(r.sink.started.count == 1 && r.sink.ended.count == 1)
        #expect(r.coordinator.isIdle && !r.coordinator.holdsLease)
        #expect(r.log.count("idle") == 1)
    }

    // MARK: cancel while a different lease is released

    @Test func aCancelWhileAnOldLeaseIsReleasedNeverActivatesAudioOrKeepsALease() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        await runOnce(r, StartOptions(keepAlive: .seconds(30))) // a lease is held
        #expect(r.log.count("activate") == 1)
        r.source.holdStop(true)
        // A start with another keep-alive has to release that lease first; the press lands meanwhile.
        let second = Task { await r.coordinator.toggle(StartOptions(keepAlive: .seconds(60))) }
        #expect(await eventually { r.log.count("source.stop") == 1 })
        #expect(await r.coordinator.toggle() == .stopped(nil))
        r.source.holdStop(false)
        #expect(await second.value == .stopped(nil))
        #expect(r.log.count("activate") == 1) // the cancelled run never touched the audio session
        #expect(r.log.count("source.start") == 1)
        #expect(!r.coordinator.holdsLease && r.coordinator.isIdle)
        #expect(r.phaseTrail.suffix(2) == [.starting, .failed])
    }

    // MARK: a release or teardown in flight serializes the next start

    @Test func aStartWaitsForAnEndKeepAliveInFlightAndTheCoordinatorIsNotIdleMeanwhile() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        await runOnce(r, Self.keyboard)
        r.source.holdStop(true)
        let ending = Task { await r.coordinator.endKeepAlive() }
        #expect(await eventually { r.log.count("source.stop") == 1 }) // releasing, not yet deactivated
        #expect(!r.coordinator.isIdle)
        let entered = Done()
        let start = Task {
            entered.value = true
            return await r.coordinator.toggle(Self.keyboard)
        }
        #expect(await eventually { entered.value })
        await Task.yield()
        #expect(r.log.count("activate") == 1) // the new session has not activated over the old teardown
        #expect(r.log.count("deactivate") == 0)
        r.source.holdStop(false)
        await ending.value
        #expect(await start.value == .started)
        let ev = r.log.events
        let released = try #require(ev.firstIndex(of: "deactivate"))
        #expect(released < ev.lastIndex(of: "activate")!)
        #expect(r.log.count("deactivate") == 1) // and nothing deactivates the new session afterwards
        _ = await r.coordinator.toggle()
    }

    @Test func aStopDuringTheSessionsOwnAbortTeardownWaitsForItToFinish() async throws {
        let r = CoordinatorRig(script: [.init(text: "partial text", isFinal: true)])
        r.attachSink()
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        #expect(await eventually { r.sink.updates.last?.committed == "partial text" })
        r.source.holdStop(true)
        r.engine.failStream(with: TestError(tag: "stream"), run: 0) // the session starts tearing itself down
        #expect(await eventually { r.log.count("source.stop") == 1 })
        let done = Done()
        let entered = Done()
        let stopping = Task {
            entered.value = true
            let outcome = await r.coordinator.toggle() // a press lands in the middle of that teardown
            done.value = true
            return outcome
        }
        #expect(await eventually { entered.value })
        await Task.yield()
        #expect(!done.value) // still waiting for the teardown
        #expect(!r.coordinator.isIdle)
        #expect(r.log.count("deactivate") == 0)
        r.source.holdStop(false)
        #expect(await stopping.value == .stopped("partial text"))
        #expect(r.coordinator.isIdle)
        let ev = r.log.events
        #expect(try #require(ev.firstIndex(of: "deactivate")) < ev.lastIndex(of: "idle")!)
        // The next start begins after the old teardown, on a fresh session.
        r.engine.clearStreamError()
        #expect(await r.coordinator.toggle() == .started)
        #expect(r.built.all.count == 2)
        #expect(try #require(r.log.events.lastIndex(of: "activate")) > r.log.events.firstIndex(of: "deactivate")!)
        _ = await r.coordinator.toggle()
    }

    @Test func aStartWhileTheHeldLeaseIsExpiringWaitsForItsTeardownThenReArms() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        await runOnce(r, Self.keyboard)
        r.source.holdStop(true)
        r.lingerClock.tick() // the window ends; the teardown starts and hangs
        #expect(await eventually { r.log.count("source.stop") == 1 })
        let entered = Done()
        let start = Task {
            entered.value = true
            return await r.coordinator.toggle(Self.keyboard)
        }
        #expect(await eventually { entered.value })
        await Task.yield()
        #expect(r.log.count("activate") == 1)
        r.source.holdStop(false)
        #expect(await start.value == .started)
        #expect(r.built.all.count == 1) // the same session re-armed
        let ev = r.log.events
        #expect(try #require(ev.firstIndex(of: "deactivate")) < ev.lastIndex(of: "activate")!)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.coordinator.holdsLease) // the lease kept after the run is the live one
    }

    // MARK: a held lease keeps its own policy

    @Test func aDeadHeldLeaseThatCannotReArmHopsWithoutAFallbackItsSessionAlreadyUsedTheDefault() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.environment.context = StartContext(inBackground: false, otherAudioPlaying: false, audioPolicy: .duckOthers)
        await runOnce(r, Self.keyboard)
        // The press now arrives under another selected policy, in the background; the held mic died.
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)
        r.source.failRoute(with: TestError(tag: "dead"))
        r.control.failActivation(with: TestError(tag: "refused"))
        #expect(await r.coordinator.toggle(Self.keyboard) == .needsForeground(.backgroundStartRefused))
        #expect(r.built.policies == [.duckOthers]) // no second session: the held one is already the default
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
        #expect(!r.coordinator.holdsLease && r.coordinator.isIdle)
    }

    @Test func aDeadHeldLeaseThatCannotReArmFallsBackFromItsOwnPolicyNotTheSelectedOne() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.environment.context = StartContext(inBackground: false, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)
        await runOnce(r, Self.keyboard) // armed under the experimental policy
        // Now the selected policy is the default, so the context alone would never retry.
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false, audioPolicy: .duckOthers)
        r.source.failRoute(with: TestError(tag: "dead"))
        r.control.failActivation(with: TestError(tag: "refused"), only: [.duckMusicPauseSpoken])
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        #expect(r.built.policies == [.duckMusicPauseSpoken, .duckOthers])
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") } == ["fallback:duckMusicPauseSpoken>duckOthers"])
        _ = await r.coordinator.toggle()
    }

    // MARK: an abort that began before the start resumed

    @Test func aRunThatAbortedWhileTheStartWasFinishingReportsTheAbortsOutcome() async throws {
        let r = CoordinatorRig(script: [.init(text: "partial text", isFinal: true)])
        r.attachSink()
        r.activity.holdUpdate = true // the start is inside its first "listening" publish
        let first = Task { await r.coordinator.toggle(Self.keyboard) }
        #expect(await eventually { r.log.count("activity.update:listening") == 1 })
        #expect(await eventually { r.sink.updates.last?.committed == "partial text" })
        r.engine.failStream(with: TestError(tag: "stream"), run: 0) // the run dies before the start returns
        #expect(await eventually { r.log.count("source.stop") == 1 })
        r.activity.holdUpdate = false
        let outcome = await first.value
        #expect(outcome == .stopped("partial text")) // not `.started` for a run that is already over
        #expect(r.coordinator.isIdle)
        #expect(r.clipboard.written == ["partial text"])
        #expect(r.sink.started.count == 1 && r.sink.ended.count == 1)
        #expect(r.log.count("idle") == 1)
        #expect(await r.history.entries.map(\.text) == ["partial text"])
    }

    // MARK: a stream failure while listening

    @Test func aStreamFailureWhileListeningSalvagesTheCommittedTextAndFreesTheNextStart() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        r.engine.emit(.init(text: "partial text", isFinal: true), run: 0)
        r.engine.emit(.init(text: "tentative", isFinal: false), run: 0)
        #expect(await eventually { r.sink.updates.last?.volatile == "tentative" })
        r.engine.failStream(with: TestError(tag: "stream"), run: 0)
        #expect(await eventually { r.log.count("idle") == 1 })
        #expect(r.clipboard.written == ["partial text"]) // committed only
        #expect(await r.history.entries.map(\.text) == ["partial text"])
        #expect(r.activity.ends.map(\.phase) == [.copied])
        #expect(r.sink.ended.map(\.text) == ["partial text"] && r.sink.ended.map(\.committed) == ["partial text"])
        #expect(r.sink.leases.isEmpty && !r.coordinator.holdsLease) // a dead session keeps no lease
        let ev = r.log.events
        #expect(try #require(ev.firstIndex(of: "deactivate")) < ev.firstIndex(of: "idle")!)
        #expect(await r.coordinator.toggle() == .started) // a fresh session, not a stop of the dead one
        #expect(r.built.all.count == 2)
        _ = await r.coordinator.toggle()
    }
}
