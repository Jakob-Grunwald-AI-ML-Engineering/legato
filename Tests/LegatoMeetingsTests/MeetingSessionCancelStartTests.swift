import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// An engine whose `prepare` ignores cancellation, like a Core ML model load: it returns when the test says so.
final class UncancellableEngine: DictationEngine {
    let id = "uncancellable"
    private let state = Mutex<(entered: Bool, waiter: CheckedContinuation<Void, Never>?, open: Bool)>((false, nil, false))
    var entered: Bool { state.withLock { $0.entered } }

    func open() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.open = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                s.entered = true
                if s.open { return true }
                s.waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
        return recFormat
    }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func finish() async throws {}
}

/// A start the user cancels (the Cancel button while "Starting meeting…") leaves nothing running or saved.
@Suite struct MeetingSessionCancelStartTests {
    private func makeSession(
        engine: any DictationEngine, mic: ScriptedSource, system: ScriptedSource, store: MeetingStore
    ) -> (MeetingSession, UUID) {
        let meeting = Meeting(title: "Cancelled", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let s = MeetingSession(
            meeting: meeting,
            sources: [MeetingSource(stream: .mic, source: mic), MeetingSource(stream: .system, source: system)],
            engine: engine, store: store, sink: RecordingSink(), convert: { $0 }, clock: { 0 })
        return (s, meeting.id)
    }

    @Test func aStartCancelledWhileAnEngineIsPreparingStartsNoSourceAndSavesNothing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = UncancellableEngine(), mic = ScriptedSource(), system = ScriptedSource()
        let store = MeetingStore(root: root)
        let (s, id) = makeSession(engine: engine, mic: mic, system: system, store: store)

        let start = Task { try await s.start() }
        #expect(await eventually { engine.entered })
        start.cancel()
        engine.open() // the model load finishes after the cancel, as it does in the app

        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(try await store.meeting(id: id) == nil, "no meeting was saved")
        #expect(try await store.meetings().isEmpty)
        // A source the session never started is stopped harmlessly; one it started must not stay running.
        #expect(mic.startCount == 0 && system.startCount == 0, "no source was started after the cancel")
    }

    @Test func aStartCancelledWhileSourcesAreStartingStopsEverySourceItStarted() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Mutex<Task<Void, any Error>?>(nil)
        let mic = ScriptedSource(onStart: { task.withLock { $0 }?.cancel() })  // the cancel lands as the mic starts
        let system = ScriptedSource()
        let store = MeetingStore(root: root)
        let (s, id) = makeSession(engine: RecordingEngine(), mic: mic, system: system, store: store)

        let start = Task { try await s.start() }
        task.withLock { $0 = start }

        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(mic.startCount == 1)
        #expect(mic.stopCount >= 1, "the mic that was started is stopped again")
        #expect(system.startCount == 0, "the cancel stops the start before the next source")
        #expect(try await store.meeting(id: id) == nil)
    }

    @Test func aStartCancelledInsideAnEngineThatHonoursCancellationTearsDownToo() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = ScriptedSource(), system = ScriptedSource()
        let (s, _) = makeSession(engine: CancellableSlowEngine(), mic: mic, system: system, store: MeetingStore(root: root))

        let start = Task { try await s.start() }
        try await Task.sleep(for: .milliseconds(20))
        start.cancel()

        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(mic.startCount == 0 && system.startCount == 0)
    }
}

/// `prepare` sleeps, so it throws when cancelled.
final class CancellableSlowEngine: DictationEngine {
    let id = "slow"
    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        try await Task.sleep(for: .seconds(30))
        return recFormat
    }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func finish() async throws {}
}
