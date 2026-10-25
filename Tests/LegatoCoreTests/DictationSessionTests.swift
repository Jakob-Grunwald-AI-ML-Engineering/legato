import Foundation
import Synchronization
import Testing
@testable import LegatoCore

@MainActor
struct Rig {
    let log = EventLog()
    let engine: FakeEngine
    let source: FakeSource
    let control: FakeSessionControl
    let history = MemoryHistory()
    let clock = ManualClock()
    let session: DictationSession

    init(linger: Duration = .zero, policy: AudioPolicy = .default,
         script: [TranscriptEvent] = [.init(text: "hello", isFinal: false), .init(text: "hello world", isFinal: true)],
         sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        engine = FakeEngine(log: log)
        engine.set(script: script)
        source = FakeSource(log: log)
        control = FakeSessionControl(log: log)
        session = DictationSession(
            engine: engine, source: source, sessionControl: control, history: history,
            policy: policy, linger: linger, sleep: sleep ?? clock.sleep,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }
}

/// Collects everything a session publishes on `edits`.
@MainActor
final class EditRecorder {
    private(set) var edits: [TranscriptEdit] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<TranscriptEdit>) {
        task = Task { [weak self] in
            for await e in stream { self?.edits.append(e) }
        }
    }
    deinit { task?.cancel() }
}

@MainActor
@Suite struct DictationSessionTests {
    // MARK: ordering

    @Test func policyActivatedBeforeSourceStarts() async throws {
        let r = Rig()
        try await r.session.start(locale: Locale(identifier: "en_US"))
        let ev = r.log.events
        let a = try #require(ev.firstIndex(of: "activate"))
        let s = try #require(ev.firstIndex(of: "source.start"))
        let p = try #require(ev.firstIndex(of: "engine.prepare"))
        #expect(p < a && a < s)
        #expect(r.control.activatedConfigs == [AudioPolicy.duckOthers.sessionConfig])
        _ = try await r.session.stop()
    }

    @Test func policyChoiceReachesSessionControl() async throws {
        let r = Rig(policy: .mixWithOthers)
        try await r.session.start()
        #expect(r.control.activatedConfigs == [AudioPolicy.mixWithOthers.sessionConfig])
        _ = try await r.session.stop()
    }

    @Test func statesAcrossRun() async throws {
        let r = Rig()
        #expect(r.session.leaseState == .idle && r.session.runState == .idle)
        try await r.session.start()
        #expect(r.session.leaseState == .armed && r.session.runState == .listening)
        _ = try await r.session.stop()
        #expect(r.session.leaseState == .idle && r.session.runState == .idle)
    }

    // MARK: failures

    @Test func startWithoutAssetsThrowsTypedErrorAndNeverActivates() async throws {
        let r = Rig()
        r.engine.set(installed: false)
        await #expect(throws: DictationError.assetsNotInstalled) { try await r.session.start() }
        #expect(r.log.count("activate") == 0)
        #expect(r.log.count("source.start") == 0)
        #expect(r.session.runState == .idle && r.session.leaseState == .idle)
    }

    @Test func prepareFailurePropagatesAndLeavesIdle() async throws {
        let r = Rig()
        r.engine.set(prepareError: TestError())
        await #expect(throws: TestError()) { try await r.session.start() }
        #expect(r.log.count("activate") == 0)
        #expect(r.session.runState == .idle)
        // A fresh start works afterwards.
        r.engine.set(prepareError: nil)
    }

    @Test func activationFailureDeactivatesAndThrows() async throws {
        let r = Rig()
        r.control.failActivation(with: TestError(tag: "act"))
        await #expect(throws: TestError(tag: "act")) { try await r.session.start() }
        #expect(r.log.count("source.start") == 0)
        #expect(r.log.count("deactivate") == 1)
        #expect(r.session.leaseState == .idle && r.session.runState == .idle)
    }

    @Test func sourceStartFailureDeactivatesAndThrows() async throws {
        let r = Rig()
        r.source.failStart(with: TestError(tag: "mic"))
        await #expect(throws: TestError(tag: "mic")) { try await r.session.start() }
        #expect(r.log.count("deactivate") == 1)
        #expect(r.session.leaseState == .idle && r.session.runState == .idle)
    }

    @Test func doubleStartIsRejectedAndFirstRunSurvives() async throws {
        let r = Rig()
        try await r.session.start()
        await #expect(throws: DictationError.alreadyRunning) { try await r.session.start() }
        #expect(r.session.runState == .listening)
        #expect(r.log.count("activate") == 1)
        _ = try await r.session.stop()
    }

    @Test func stopWithoutRunThrowsNotRunning() async throws {
        let r = Rig()
        await #expect(throws: DictationError.notRunning) { _ = try await r.session.stop() }
    }

    @Test func stopWhilePreparingCancelsCleanly() async throws {
        let r = Rig()
        r.engine.set(hangInPrepare: true)
        let starting = Task { try await r.session.start() }
        #expect(await eventually { r.session.runState == .preparing })
        let entry = try await r.session.stop()
        #expect(entry == nil)
        await #expect(throws: DictationError.cancelled) { try await starting.value }
        #expect(r.session.runState == .idle && r.session.leaseState == .idle)
        #expect(r.log.count("activate") == 0)
        #expect(await r.history.entries.isEmpty)
    }

    @Test func engineStreamErrorAbortsRunAndDeactivates() async throws {
        let r = Rig()
        r.engine.set(script: [], streamError: TestError(tag: "stream"))
        try await r.session.start()
        #expect(await eventually { r.session.runState == .idle })
        #expect(r.log.count("deactivate") == 1)
        #expect(r.log.count("source.stop") == 1)
        #expect(r.session.leaseState == .idle)
        #expect(r.session.lastError as? TestError == TestError(tag: "stream"))
    }

    // MARK: abort hook

    @Test func abortFiresHookOnceAfterTeardown() async throws {
        let r = Rig()
        r.engine.set(script: [.init(text: "partial", isFinal: true)], streamError: TestError(tag: "stream"))
        var calls: [(run: DictationSession.RunState, lease: DictationSession.LeaseState, error: TestError?)] = []
        r.session.onRunAborted = { [session = r.session] error in
            calls.append((session.runState, session.leaseState, error as? TestError))
        }
        try await r.session.start()
        #expect(await eventually { !calls.isEmpty })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(calls.count == 1)
        #expect(calls.first?.run == .idle && calls.first?.lease == .idle) // torn down before the hook runs
        #expect(calls.first?.error == TestError(tag: "stream"))
    }

    @Test func normalStopDoesNotFireAbortHook() async throws {
        let r = Rig()
        var fired = 0
        r.session.onRunAborted = { _ in fired += 1 }
        try await r.session.start()
        _ = try await r.session.stop()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fired == 0)
    }

    @Test func failureReportedByStopDoesNotFireAbortHook() async throws {
        let r = Rig()
        r.engine.set(finishError: TestError(tag: "fin"))
        var fired = 0
        r.session.onRunAborted = { _ in fired += 1 }
        try await r.session.start()
        await #expect(throws: TestError(tag: "fin")) { _ = try await r.session.stop() } // stop() reports it itself
        #expect(fired == 0)
    }

    @Test func partialEntryHoldsTheTextCommittedBeforeAnAbort() async throws {
        let r = Rig(script: [.init(text: "kept ", isFinal: true), .init(text: "tentative", isFinal: false)])
        r.engine.set(streamError: TestError(tag: "stream"))
        try await r.session.start(locale: Locale(identifier: "de_DE"))
        #expect(await eventually { r.session.runState == .idle })
        let entry = try #require(r.session.partialEntry())
        #expect(entry.text == "kept") // trimmed, volatile text excluded
        #expect(entry.localeIdentifier == "de_DE" && entry.engineID == "fake")
        #expect(await r.history.entries.isEmpty) // the session never writes it; the caller decides
    }

    @Test func partialEntryIsNilWithoutCommittedText() async throws {
        let r = Rig(script: [.init(text: "tentative", isFinal: false)])
        r.engine.set(streamError: TestError(tag: "stream"))
        try await r.session.start()
        #expect(await eventually { r.session.runState == .idle })
        #expect(r.session.partialEntry() == nil)
    }

    @Test func finishFailureStillDeactivates() async throws {
        let r = Rig()
        r.engine.set(finishError: TestError(tag: "fin"))
        try await r.session.start()
        await #expect(throws: TestError(tag: "fin")) { _ = try await r.session.stop() }
        #expect(r.log.count("deactivate") == 1)
        #expect(r.session.runState == .idle && r.session.leaseState == .idle)
    }

    // MARK: run isolation

    @Test func finishFailureDoesNotLeakRunOneIntoRunTwo() async throws {
        let r = Rig(script: [.init(text: "run1", isFinal: true)])
        // Run 1: finish() throws while its results stream stays open and keeps emitting.
        r.engine.set(finishError: TestError(tag: "fin"), holdStreamOpen: true)
        try await r.session.start()
        await #expect(throws: TestError(tag: "fin")) { _ = try await r.session.stop() }

        r.engine.clearFinishError()
        r.engine.set(script: [.init(text: "run2", isFinal: true)], holdStreamOpen: false)
        try await r.session.start()
        // Late traffic from run 1's stream: an event, then a failure.
        r.engine.emit(.init(text: " LATE", isFinal: true), run: 0)
        r.engine.failStream(with: TestError(tag: "late"), run: 0)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(r.session.runState == .listening)
        #expect(r.session.lastError == nil)
        let entry = try await r.session.stop()
        #expect(entry?.text == "run2")
        #expect(await r.history.entries.map(\.text) == ["run2"])
    }

    @Test func startAfterCancelledStartIsNotShadowedByTheOldCallersDefer() async throws {
        let r = Rig()
        r.engine.set(hangInPrepare: true)
        let a = Task { try await r.session.start() }
        #expect(await eventually { r.session.runState == .preparing })
        // B starts the moment A's run is idle again: after A's task completed, before A's caller
        // (and its `defer`) resumes. Yielding keeps B's job ahead of A's resumption in the queue.
        let b = Task {
            while r.session.runState != .idle { await Task.yield() }
            try? await r.session.start()
        }
        _ = try await r.session.stop() // cancels A
        #expect(await eventually { r.session.runState == .preparing }) // B is now preparing
        _ = try await r.session.stop() // must cancel B
        let stateAfterSecondStop = r.session.runState
        r.engine.set(hangInPrepare: false) // releases B if the stop failed to cancel it
        await b.value
        _ = await a.result
        #expect(stateAfterSecondStop == .idle)
        #expect(r.log.count("source.start") == 0)
        if r.session.runState != .idle { _ = try? await r.session.stop() }
    }

    // MARK: volatile text never outlives a run

    @Test func streamErrorAbortClearsVolatileText() async throws {
        let r = Rig()
        r.engine.set(script: [.init(text: "hello wor", isFinal: false)], streamError: TestError(tag: "stream"))
        let rec = EditRecorder(r.session.edits)
        try await r.session.start()
        #expect(await eventually { r.session.runState == .idle })
        #expect(await eventually { rec.edits.last == .replaceVolatile("") })
        #expect(rec.edits == [.replaceVolatile("hello wor"), .replaceVolatile("")])
    }

    @Test func finishFailureClearsVolatileText() async throws {
        let r = Rig(script: [.init(text: "hello wor", isFinal: false)])
        r.engine.set(finishError: TestError(tag: "fin"), holdStreamOpen: true)
        let rec = EditRecorder(r.session.edits)
        try await r.session.start()
        #expect(await eventually { rec.edits.count == 1 })
        await #expect(throws: TestError(tag: "fin")) { _ = try await r.session.stop() }
        #expect(await eventually { rec.edits.last == .replaceVolatile("") })
        #expect(rec.edits == [.replaceVolatile("hello wor"), .replaceVolatile("")])
    }

    @Test func stopWithVolatileButNoFinalClearsVolatileText() async throws {
        let r = Rig(script: [.init(text: "hello wor", isFinal: false)])
        let rec = EditRecorder(r.session.edits)
        try await r.session.start()
        #expect(await eventually { rec.edits.count == 1 })
        #expect(try await r.session.stop() == nil)
        #expect(await eventually { rec.edits.last == .replaceVolatile("") })
        #expect(rec.edits == [.replaceVolatile("hello wor"), .replaceVolatile("")])
    }

    // MARK: dead armed source

    @Test func failingRouteReArmsTheLeaseAndRunGoesLive() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start(); _ = try await r.session.stop()
        #expect(r.session.leaseState == .armed)
        r.source.failRoute(with: TestError(tag: "route"))

        try await r.session.start()
        #expect(r.session.runState == .listening && r.session.leaseState == .armed)
        #expect(r.log.count("source.route") == 1)
        #expect(r.log.count("deactivate") == 1) // the dead lease was torn down
        #expect(r.log.count("activate") == 2)
        #expect(r.log.count("source.start") == 2)
        #expect(try await r.session.stop()?.text == "hello world")
    }

    // MARK: normal exit, linger == 0

    @Test func stopDeactivatesImmediatelyWhenLingerZero() async throws {
        let r = Rig()
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(r.log.count("deactivate") == 1)
        #expect(r.log.count("source.stop") == 1)
        let ev = r.log.events
        #expect(try #require(ev.firstIndex(of: "engine.finish")) < ev.firstIndex(of: "deactivate")!)
    }

    // MARK: history / entry

    @Test func stopReturnsEntryAndAppendsToHistory() async throws {
        let r = Rig()
        try await r.session.start(locale: Locale(identifier: "de_DE"))
        let entry = try #require(try await r.session.stop())
        #expect(entry.text == "hello world")
        #expect(entry.localeIdentifier == "de_DE")
        #expect(entry.engineID == "fake")
        #expect(await r.history.entries == [entry])
    }

    @Test func emptyFinalIsNotAppended() async throws {
        let r = Rig(script: [.init(text: "um", isFinal: false), .init(text: "", isFinal: true)])
        try await r.session.start()
        #expect(try await r.session.stop() == nil)
        #expect(await r.history.entries.isEmpty)
    }

    @Test func volatileOnlyIsNotAppended() async throws {
        let r = Rig(script: [.init(text: "hello", isFinal: false)])
        try await r.session.start()
        #expect(try await r.session.stop() == nil)
        #expect(await r.history.entries.isEmpty)
    }

    @Test func editsArePublished() async throws {
        let r = Rig()
        var it = r.session.edits.makeAsyncIterator()
        try await r.session.start()
        #expect(await it.next() == .replaceVolatile("hello"))
        #expect(await it.next() == .replaceVolatile(""))
        #expect(await it.next() == .commit(delta: "hello world"))
        _ = try await r.session.stop()
    }

    // MARK: linger

    @Test func lingerKeepsLeaseAndSecondRunReusesIt() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(r.session.leaseState == .armed && r.session.runState == .idle)
        #expect(r.log.count("deactivate") == 0)
        #expect(r.log.count("source.stop") == 0)

        try await r.session.start()
        #expect(r.log.count("activate") == 1)
        #expect(r.log.count("source.start") == 1)
        #expect(r.log.count("source.route") == 1)
        let second = try await r.session.stop()
        #expect(second?.text == "hello world")
        #expect(r.log.count("deactivate") == 0)
    }

    @Test func startCancelsPendingLingerExpiry() async throws {
        let clock = ManualClock()
        let cancelledSleeps = Mutex(0)
        let r = Rig(linger: .seconds(30), sleep: { duration in
            try await withTaskCancellationHandler {
                try await clock.sleep(duration)
            } onCancel: {
                cancelledSleeps.withLock { $0 += 1 }
            }
        })
        try await r.session.start(); _ = try await r.session.stop() // linger sleeper pending
        try await r.session.start()
        // The pending expiry itself was cancelled (a bare tick can't tell: the cancelled sleeper eats it).
        #expect(cancelledSleeps.withLock { $0 } == 1)
        clock.tick() // would expire the first linger if it were still pending
        clock.tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.log.count("deactivate") == 0)
        #expect(r.session.leaseState == .armed)
        _ = try await r.session.stop()
    }

    @Test func leaseDeactivatesAfterLingerExpires() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start(); _ = try await r.session.stop()
        #expect(r.log.count("deactivate") == 0)
        r.clock.tick()
        #expect(await eventually { r.session.leaseState == .idle })
        #expect(r.log.count("deactivate") == 1)
        #expect(r.log.count("source.stop") == 1)
    }

    @Test func runAfterLingerExpiryReactivates() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start(); _ = try await r.session.stop()
        r.clock.tick()
        #expect(await eventually { r.session.leaseState == .idle })
        try await r.session.start()
        #expect(r.log.count("activate") == 2)
        #expect(r.log.count("source.start") == 2)
        _ = try await r.session.stop()
    }

    @Test func failureWithLingerDeactivatesImmediately() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start(); _ = try await r.session.stop()
        r.engine.set(prepareError: TestError())
        await #expect(throws: TestError()) { try await r.session.start() }
        #expect(r.log.count("deactivate") == 1)
        #expect(r.session.leaseState == .idle)
    }
}

// MARK: lease control for keep-alive

extension DictationSessionTests {
    @Test func endLeaseTearsDownAHeldLeaseAtOnce() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(r.session.leaseState == .armed)
        await r.session.endLease()
        #expect(r.session.leaseState == .idle)
        #expect(r.log.count("deactivate") == 1)
        r.clock.tick() // the cancelled linger must not tear down a second time
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.log.count("deactivate") == 1)
    }

    @Test func endLeaseDuringARunLeavesItAlone() async throws {
        let r = Rig(linger: .seconds(30))
        try await r.session.start()
        await r.session.endLease()
        #expect(r.session.leaseState == .armed && r.session.runState == .listening)
        #expect(r.log.count("deactivate") == 0)
        _ = try await r.session.stop()
    }

    @Test func endLeaseWithNoLeaseDoesNothing() async throws {
        let r = Rig(linger: .seconds(30))
        await r.session.endLease()
        #expect(r.log.events.isEmpty)
    }

    @Test func leaseExpiryFiresTheHookOnceAfterTeardown() async throws {
        let r = Rig(linger: .seconds(30))
        let fired = Fired()
        r.session.onLeaseExpired = { fired.count += 1; fired.leaseWasIdle = r.session.leaseState == .idle }
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(fired.count == 0)
        r.clock.tick()
        #expect(await eventually { fired.count == 1 })
        #expect(fired.leaseWasIdle)
        #expect(r.log.count("deactivate") == 1)
    }

    @Test func theExpiryHookStaysQuietWhenTheLeaseIsEndedOrNeverHeld() async throws {
        let ended = Rig(linger: .seconds(30))
        let fired = Fired()
        ended.session.onLeaseExpired = { fired.count += 1 }
        try await ended.session.start()
        _ = try await ended.session.stop()
        await ended.session.endLease()
        let plain = Rig()
        plain.session.onLeaseExpired = { fired.count += 1 }
        try await plain.session.start()
        _ = try await plain.session.stop()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fired.count == 0)
    }

    @Test func editCountCountsEveryEditPublished() async throws {
        let r = Rig()
        let recorder = EditRecorder(r.session.edits)
        try await r.session.start()
        _ = try await r.session.stop()
        #expect(await eventually { recorder.edits.count == r.session.editCount })
        #expect(r.session.editCount > 0)
    }
}

@MainActor
private final class Fired {
    var count = 0
    var leaseWasIdle = false
}
