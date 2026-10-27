import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// What a session does when an engine, a source or the store misbehaves.
@Suite struct MeetingSessionRobustnessTests {
    private func session(
        mic: any AudioSource, micEngine: any DictationEngine, store: MeetingStore, sink: RecordingSink,
        extra: [MeetingInput] = []
    ) -> (MeetingSession, Meeting) {
        let meeting = Meeting(title: "Robust", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let s = MeetingSession(
            meeting: meeting, inputs: [MeetingInput(stream: .mic, source: mic, engine: micEngine)] + extra,
            store: store, sink: sink, convert: { $0 }, clock: { 0 })
        return (s, meeting)
    }

    @Test func aFailedEngineStopsReceivingAudioWhileTheSinkKeepsRecording() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptedSource(), engine = FailingEngine(), sink = RecordingSink()
        let (s, _) = session(mic: source, micEngine: engine, store: MeetingStore(root: root), sink: sink)
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = s.snapshots
        let collector = Task { for await snap in snapshots { latest.withLock { $0 = snap } } }
        defer { collector.cancel() }
        try await s.start()

        source.push(tone(160))
        #expect(await eventually { latest.withLock { $0 }?.engineErrors[.mic] != nil })
        // The failed engine's feed is finished, so nothing piles up behind it.
        #expect(await eventually { engine.inputEnded })
        let before = engine.received
        for _ in 0..<5 { source.push(tone(160)) }
        #expect(await eventually { sink.calls.count == 6 })
        #expect(engine.received == before)
        _ = await s.stop()
    }

    @Test func aLaggingEngineHoldsOnlyTheNewestAudio() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptedSource(), engine = GatedEngine(), sink = RecordingSink()
        let meeting = Meeting(title: "Lag", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let s = MeetingSession(
            meeting: meeting, inputs: [MeetingInput(stream: .mic, source: source, engine: engine)],
            store: MeetingStore(root: root), sink: sink, convert: { $0 }, clock: { 0 }, feedCapacity: 3)
        try await s.start()

        for i in 1...10 { source.push(tone(10, Float(i) / 100)) }
        #expect(await eventually { sink.calls.count == 10 })  // the recording loses nothing
        engine.open()
        #expect(await eventually { engine.chunks.count >= 1 })
        _ = await s.stop()
        #expect(engine.chunks.count <= 3)
        #expect(engine.chunks.last?.samples.first == 0.1)  // the newest survived
    }

    @Test func aSourceWhoseStreamEndsEarlyIsReportedAsAnAudioError() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptedSource(), engine = RecordingEngine(), sink = RecordingSink()
        let (s, _) = session(mic: source, micEngine: engine, store: MeetingStore(root: root), sink: sink)
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = s.snapshots
        let collector = Task { for await snap in snapshots { latest.withLock { $0 = snap } } }
        defer { collector.cancel() }
        try await s.start()

        source.endStream()
        #expect(await eventually { latest.withLock { $0 }?.audioError != nil })
        _ = await s.stop()
    }

    @Test func aNormalStopIsNotAnAudioError() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptedSource(), engine = RecordingEngine(), sink = RecordingSink()
        let (s, _) = session(mic: source, micEngine: engine, store: MeetingStore(root: root), sink: sink)
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = s.snapshots
        let collector = Task { for await snap in snapshots { latest.withLock { $0 = snap } } }
        try await s.start()
        _ = await s.stop()
        await collector.value
        #expect(latest.withLock { $0 }?.audioError == nil)
    }

    @Test func aFailingStoreStopsEverySourceItStarted() async throws {
        let root = tempRoot()
        try Data("not a folder".utf8).write(to: root)  // a file where the meetings folder should be
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = ScriptedSource(), system = ScriptedSource()
        let micEngine = RecordingEngine(), systemEngine = RecordingEngine()
        let (s, _) = session(
            mic: mic, micEngine: micEngine, store: MeetingStore(root: root), sink: RecordingSink(),
            extra: [MeetingInput(stream: .system, source: system, engine: systemEngine)])

        await #expect(throws: (any Error).self) { try await s.start() }
        #expect(mic.stopCount == 1 && system.stopCount == 1)
        #expect(micEngine.finishCount == 1 && systemEngine.finishCount == 1)
    }

    @Test func aRenameDuringTheMeetingSurvivesMuteAndStop() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let source = ScriptedSource(), engine = RecordingEngine(), sink = RecordingSink()
        let (s, meeting) = session(mic: source, micEngine: engine, store: store, sink: sink)
        try await s.start()

        var renamed = try #require(try await store.meeting(id: meeting.id))
        renamed.title = "Renamed by the user"
        try await store.update(renamed)

        await s.setMuted(true, stream: .mic)
        await s.setMuted(false, stream: .mic)
        let finished = await s.stop()
        #expect(try await store.meeting(id: meeting.id)?.title == "Renamed by the user")
        #expect(finished.title == "Renamed by the user")
        #expect(try await store.meeting(id: meeting.id)?.state == .processing)
    }
}
