import Foundation
import Testing
@testable import LegatoCore

/// Keep-alive, the activity policy, the transcript sink and the conditional clipboard.
@MainActor
@Suite struct DictationCoordinatorKeepAliveTests {
    typealias Outcome = DictationCoordinator.Outcome

    static let keepAlive = StartOptions(keepAlive: .seconds(30))
    static let keyboard = StartOptions(keepAlive: .seconds(30), target: .keyboard)

    private func runOnce(_ r: CoordinatorRig, _ options: StartOptions) async throws {
        #expect(await r.coordinator.toggle(options) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    // MARK: keep-alive

    @Test func twoRunsInsideTheKeepAliveWindowUseOneSession() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        try await runOnce(r, Self.keepAlive)
        try await runOnce(r, Self.keepAlive)
        #expect(r.built.all.count == 1)
        #expect(r.built.lingers == [.seconds(30)])
        #expect(r.log.count("activate") == 1) // armed once
        #expect(r.log.count("source.start") == 1 && r.log.count("source.route") == 1)
        #expect(r.log.count("deactivate") == 0) // still held between and after the runs
        #expect(r.log.count("engine.prepare") == 2)
        #expect(r.log.count("activity.request:starting") == 2) // every run has its own activity
        #expect(await r.history.entries.map(\.text) == ["hello world", "hello world"])
    }

    @Test func afterTheWindowExpiresTheNextStartBuildsANewSession() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        try await runOnce(r, Self.keepAlive)
        r.lingerClock.tick() // the 30 s are over
        #expect(await eventually { r.log.count("deactivate") == 1 })
        try await runOnce(r, Self.keepAlive)
        #expect(r.built.all.count == 2)
        #expect(r.log.count("activate") == 2)
    }

    @Test func withoutKeepAliveTheFactoryIsAskedForNoLinger() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        try await runOnce(r, StartOptions())
        #expect(r.built.lingers == [.zero])
        #expect(r.log.count("deactivate") == 1) // torn down at once, as before
    }

    @Test func aDifferentKeepAliveBuildsANewSessionAfterReleasingTheHeldOne() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        try await runOnce(r, StartOptions(keepAlive: .seconds(30)))
        try await runOnce(r, StartOptions(keepAlive: .seconds(60)))
        #expect(r.built.lingers == [.seconds(30), .seconds(60)])
        let ev = r.log.events
        let released = try #require(ev.firstIndex(of: "deactivate"))
        let secondArm = try #require(ev.lastIndex(of: "activate"))
        #expect(released < secondArm)
    }

    @Test func aRunWithoutKeepAliveEndsAHeldLeaseAndKeepsLingerZero() async throws {
        // The Action Button without the keyboard keeps its old behaviour even after a keyboard run.
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        try await runOnce(r, Self.keepAlive)
        try await runOnce(r, StartOptions())
        #expect(r.built.lingers == [.seconds(30), .zero])
        #expect(r.log.count("activate") == 2)
        #expect(r.log.count("deactivate") == 2)
    }

    @Test func endKeepAliveReleasesTheHeldLeaseAndTheNextStartIsFresh() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        try await runOnce(r, Self.keepAlive)
        #expect(r.sink.leases.map { $0 != nil } == [true])
        await r.coordinator.endKeepAlive()
        #expect(r.log.count("deactivate") == 1)
        #expect(r.sink.leases.map { $0 != nil } == [true, false])
        try await runOnce(r, Self.keepAlive)
        #expect(r.built.all.count == 2)
    }

    @Test func endKeepAliveWithNothingHeldDoesNothing() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        await r.coordinator.endKeepAlive()
        #expect(r.log.events.isEmpty)
    }

    @Test func endKeepAliveDuringARunLeavesTheRunAlone() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle(Self.keepAlive) == .started)
        await r.coordinator.endKeepAlive()
        #expect(r.log.count("deactivate") == 0)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    @Test func theLeaseEndIsReportedToTheSink() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        try await runOnce(r, Self.keepAlive)
        let until = try #require(r.sink.leases.first ?? nil)
        #expect(until == r.time.now.addingTimeInterval(30))
        r.lingerClock.tick()
        #expect(await eventually { r.sink.leases.count == 2 })
        #expect(r.sink.leases.map { $0 != nil } == [true, false])
    }

    @Test func noLeaseIsReportedWithoutKeepAlive() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        try await runOnce(r, StartOptions())
        #expect(r.sink.leases.isEmpty)
    }

    @Test func theEditsConsumerSurvivesRunsOnAHeldSession() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        r.time.advance(1)
        r.engine.emit(.init(text: "one", isFinal: true), run: 0)
        #expect(await eventually { r.sink.updates.last?.committed == "one" })
        #expect(await r.coordinator.toggle() == .stopped("one"))

        #expect(await r.coordinator.toggle(Self.keyboard) == .started) // same session, same stream
        #expect(r.built.all.count == 1)
        r.time.advance(1)
        r.engine.emit(.init(text: "two", isFinal: false), run: 1)
        #expect(await eventually { r.sink.updates.last?.volatile == "two" })
        #expect(await eventually { r.activity.updates.last?.content.tail == "two" })
        r.engine.emit(.init(text: "two ", isFinal: true), run: 1)
        #expect(await r.coordinator.toggle() == .stopped("two"))
        #expect(r.sink.ended.map(\.committed) == ["one", "two "])
    }

    // MARK: activity policy

    @Test func bestEffortStartsWithoutAnActivityWhenTheSystemRefusesOne() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.activity.requestError = TestError(tag: "activities")
        #expect(await r.coordinator.toggle(StartOptions(activity: .bestEffort)) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.activity.updates.isEmpty && r.activity.ends.isEmpty) // nothing to update or end
        #expect(r.clipboard.written == ["hello world"])
        #expect(r.log.count("idle") == 1)
    }

    @Test func bestEffortStartsWhenLiveActivitiesAreDisabled() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.readiness.issue = .liveActivitiesDisabled
        #expect(await r.coordinator.toggle(StartOptions(activity: .bestEffort)) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    @Test func bestEffortStillNeedsTheOtherReadinessItems() async throws {
        for issue in [ReadinessIssue.micPermission, .assetsMissing] {
            let r = CoordinatorRig()
            r.readiness.issue = issue
            #expect(await r.coordinator.toggle(StartOptions(activity: .bestEffort)) == .needsOnboarding(issue))
            #expect(r.built.all.isEmpty)
        }
    }

    @Test func requiredStillRefusesWhenLiveActivitiesAreDisabled() async throws {
        let r = CoordinatorRig()
        r.readiness.issue = .liveActivitiesDisabled
        #expect(await r.coordinator.toggle(StartOptions(activity: .required)) == .needsOnboarding(.liveActivitiesDisabled))
        #expect(r.built.all.isEmpty)
    }

    @Test func bestEffortWithAnActivityBehavesLikeRequired() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle(StartOptions(activity: .bestEffort)) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.phaseTrail == [.starting, .listening, .finishing, .copied])
    }

    // MARK: sink

    @Test func theSinkSeesARunInOrder() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        try await runOnce(r, Self.keyboard)
        var trail: [String] = []
        for e in r.log.events where e.hasPrefix("sink.") && e != trail.last { trail.append(e) }
        #expect(trail == ["sink.runStarted:keyboard", "sink.update", "sink.runEnded", "sink.lease:set"])
        let ev = r.log.events
        let request = try #require(ev.firstIndex(of: "activity.request:starting"))
        let started = try #require(ev.firstIndex(of: "sink.runStarted:keyboard"))
        let prepare = try #require(ev.firstIndex(of: "engine.prepare"))
        #expect(request < started && started < prepare)
        // The sink is asked before the clipboard and the activity end.
        let ended = try #require(ev.firstIndex(of: "sink.runEnded"))
        #expect(ended < ev.firstIndex(of: "clipboard.write")! && ended < ev.firstIndex(of: "activity.end:copied")!)
    }

    @Test func theSinkGetsTheRunsTargetAndAFreshIdPerRun() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        try await runOnce(r, StartOptions())
        try await runOnce(r, Self.keyboard)
        #expect(r.sink.started.map(\.target) == [.app, .keyboard])
        #expect(Set(r.sink.started.map(\.id)).count == 2)
        #expect(r.sink.ended.map(\.run) == r.sink.started)
    }

    @Test func theSinkGetsCommittedAndVolatileTextAsTheRunGoes() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        #expect(r.sink.updates.last?.committed == "" && r.sink.updates.last?.volatile == "") // listening, nothing yet
        r.engine.emit(.init(text: "hel", isFinal: false), run: 0)
        #expect(await eventually { r.sink.updates.last?.volatile == "hel" })
        r.engine.emit(.init(text: "hello ", isFinal: true), run: 0)
        #expect(await eventually { r.sink.updates.last?.committed == "hello " })
        #expect(r.sink.updates.last?.volatile == "")
        _ = await r.coordinator.toggle()
    }

    @Test func theSinkGetsTheWordsFinalizedWhileStopping() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        _ = await r.coordinator.toggle(Self.keyboard)
        r.engine.emit(.init(text: "hello world", isFinal: true), run: 0)
        #expect(await r.coordinator.toggle() == .stopped("hello world")) // no waiting in between
        #expect(r.sink.ended.first?.committed == "hello world")
        #expect(r.sink.ended.first?.text == "hello world")
    }

    @Test func aFailedStartReachesTheSinkAsStartedThenEndedWithoutText() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        r.engine.set(prepareError: TestError(tag: "prep"))
        guard case .failed = await r.coordinator.toggle(Self.keyboard) else {
            Issue.record("expected .failed")
            return
        }
        #expect(r.sink.started.count == 1 && r.sink.ended.count == 1)
        #expect(r.sink.ended.first?.text == nil && r.sink.ended.first?.committed == "")
        #expect(r.sink.leases.isEmpty)
    }

    @Test func aStartThatNeverBeganTellsTheSinkNothing() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        r.readiness.issue = .micPermission
        _ = await r.coordinator.toggle(Self.keyboard)
        r.readiness.issue = nil
        r.activity.requestError = TestError(tag: "activities")
        _ = await r.coordinator.toggle(Self.keyboard) // required activity refused
        #expect(r.sink.started.isEmpty && r.sink.ended.isEmpty && r.sink.updates.isEmpty)
    }

    @Test func nothingFinalRecognizedEndsTheRunWithoutText() async throws {
        let r = CoordinatorRig(script: [.init(text: "um", isFinal: false)])
        r.attachSink()
        _ = await r.coordinator.toggle(Self.keyboard)
        #expect(await r.coordinator.toggle() == .stopped(nil))
        #expect(r.sink.ended.count == 1 && r.sink.ended.first?.text == nil)
    }

    @Test func anAbortedRunReachesTheSinkOnce() async throws {
        let r = CoordinatorRig(script: [.init(text: "partial text", isFinal: true)])
        r.attachSink()
        r.engine.set(streamError: TestError(tag: "stream"))
        _ = await r.coordinator.toggle(Self.keyboard)
        #expect(await eventually { r.log.count("idle") == 1 })
        #expect(r.sink.ended.count == 1)
        #expect(r.sink.ended.first?.committed == "partial text" && r.sink.ended.first?.text == "partial text")
        #expect(r.sink.leases.isEmpty) // an aborted run keeps no lease
    }

    // MARK: clipboard

    @Test func aFinalTextTheKeyboardAppliedIsNotCopied() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        r.sink.finalApplied = true
        #expect(await r.coordinator.toggle(Self.keyboard) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.clipboard.written.isEmpty)
        let end = try #require(r.activity.ends.first)
        #expect(r.activity.ends.count == 1 && end.phase == .copied && end.tail == "hello world")
        #expect(await r.history.entries.map(\.text) == ["hello world"]) // history is unaffected
    }

    @Test func aFinalTextTheKeyboardDidNotApplyIsCopied() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        r.sink.finalApplied = false
        _ = await r.coordinator.toggle(Self.keyboard)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.clipboard.written == ["hello world"])
        #expect(r.activity.ends.map(\.phase) == [.copied])
    }

    @Test func aClipboardThatDidNotChangeStillEndsTapToCopyWhenNotApplied() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        r.clipboard.changes = false
        _ = await r.coordinator.toggle(Self.keyboard)
        _ = await r.coordinator.toggle()
        #expect(r.activity.ends.map(\.phase) == [.tapToCopy])
    }

    @Test func anAbortedRunTheKeyboardAppliedIsNotCopiedEither() async throws {
        let r = CoordinatorRig(script: [.init(text: "partial text", isFinal: true)])
        r.attachSink()
        r.sink.finalApplied = true
        r.engine.set(streamError: TestError(tag: "stream"))
        _ = await r.coordinator.toggle(Self.keyboard)
        #expect(await eventually { r.log.count("idle") == 1 })
        #expect(r.clipboard.written.isEmpty)
        #expect(r.activity.ends.map(\.phase) == [.copied])
    }

    @Test func withoutASinkTheClipboardIsAlwaysWritten() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        _ = await r.coordinator.toggle(Self.keyboard) // a keyboard target, but nobody to report back
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(r.clipboard.written == ["hello world"])
    }

    // MARK: state

    @Test func isIdleIsFalseOnlyWhileARunIsInProgress() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(r.coordinator.isIdle)
        _ = await r.coordinator.toggle()
        #expect(!r.coordinator.isIdle)
        _ = await r.coordinator.toggle()
        #expect(r.coordinator.isIdle)
    }

    @Test func aHeldLeaseKeepsTheCoordinatorIdle() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        try await runOnce(r, Self.keepAlive)
        #expect(r.coordinator.isIdle)
        #expect(r.coordinator.holdsLease)
        await r.coordinator.endKeepAlive()
        #expect(!r.coordinator.holdsLease)
    }
}
