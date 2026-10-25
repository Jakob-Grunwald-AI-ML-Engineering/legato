import Foundation
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
         script: [TranscriptEvent] = [.init(text: "hello", isFinal: false), .init(text: "hello world", isFinal: true)]) {
        engine = FakeEngine(log: log)
        engine.set(script: script)
        source = FakeSource(log: log)
        control = FakeSessionControl(log: log)
        session = DictationSession(
            engine: engine, source: source, sessionControl: control, history: history,
            policy: policy, linger: linger, sleep: clock.sleep,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }
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

    @Test func finishFailureStillDeactivates() async throws {
        let r = Rig()
        r.engine.set(finishError: TestError(tag: "fin"))
        try await r.session.start()
        await #expect(throws: TestError(tag: "fin")) { _ = try await r.session.stop() }
        #expect(r.log.count("deactivate") == 1)
        #expect(r.session.runState == .idle && r.session.leaseState == .idle)
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
        let r = Rig(linger: .seconds(30))
        try await r.session.start(); _ = try await r.session.stop()
        try await r.session.start()
        r.clock.tick() // would expire the first linger if it were still pending
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
