import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// What a session does when its engine, a source or the store misbehaves. Ported from the two-engine session
/// to the mixed one.
@Suite struct MeetingSessionRobustnessTests {
    private func session(
        mic: any AudioSource, system: (any AudioSource)? = nil, engine: any DictationEngine, store: MeetingStore,
        sink: RecordingSink, clock: @escaping @Sendable () -> TimeInterval = { 0 }, feedCapacity: Int = 1_500
    ) -> (MeetingSession, Meeting) {
        let meeting = Meeting(title: "Robust", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        var sources = [MeetingSource(stream: .mic, source: mic)]
        if let system { sources.append(MeetingSource(stream: .system, source: system)) }
        let s = MeetingSession(
            meeting: meeting, sources: sources, engine: engine, store: store, sink: sink, convert: { $0 }, clock: clock,
            feedCapacity: feedCapacity)
        return (s, meeting)
    }

    @Test func aFailedEngineStopsReceivingAudioWhileTheSinkKeepsRecording() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptedSource(), engine = FailingEngine(), sink = RecordingSink()
        let (s, _) = session(mic: source, engine: engine, store: MeetingStore(root: root), sink: sink)
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = s.snapshots
        let collector = Task { for await snap in snapshots { latest.withLock { $0 = snap } } }
        defer { collector.cancel() }
        try await s.start()

        source.push(tone(160))
        #expect(await eventually { latest.withLock { $0 }?.engineErrors[.mixed] != nil })
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
        let mic = ScriptedSource(), system = ScriptedSource(), engine = GatedEngine(), sink = RecordingSink()
        let clock = TestClock()
        // A feed of 15 source chunks holds 3 frames of the mix.
        let (s, _) = session(
            mic: mic, system: system, engine: engine, store: MeetingStore(root: root), sink: sink,
            clock: { clock.now }, feedCapacity: 15)
        try await s.start()

        let micWrites: @Sendable () -> Int = { sink.calls.filter { if case .write(.mic, _) = $0 { true } else { false } }.count }
        for i in 1...10 {  // one frame each, as it is heard
            clock.now = Double(i) / 10
            mic.push(tone(1_600, Float(i) / 100))
            _ = await eventually { micWrites() == i }
        }
        clock.now = 1.2  // ten frames are due, and the engine has read none
        let mixed: @Sendable () -> Int = { sink.calls.reduce(0) { n, c in if case .write(.mixed, let x) = c { n + x.count } else { n } } }
        #expect(await eventually { mixed() == 16_000 }, "the recording loses nothing")
        engine.open()
        #expect(await eventually { engine.chunks.count == 3 })
        _ = await s.stop()
        let firsts = engine.chunks.map { $0.samples.first ?? -1 }
        #expect(Array(firsts.prefix(3)) == [0.08, 0.09, 0.1], "the newest three survived")
        #expect(engine.chunks.count == 5, "and the last 0.2 s cut at the stop")
    }

    @Test func aSourceWhoseStreamEndsEarlyIsReportedAsAnAudioError() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScriptedSource(), engine = RecordingEngine(), sink = RecordingSink()
        let (s, _) = session(mic: source, engine: engine, store: MeetingStore(root: root), sink: sink)
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
        let (s, _) = session(mic: source, engine: engine, store: MeetingStore(root: root), sink: sink)
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = s.snapshots
        let collector = Task { for await snap in snapshots { latest.withLock { $0 = snap } } }
        try await s.start()
        _ = await s.stop()
        await collector.value
        #expect(latest.withLock { $0 }?.audioError == nil)
    }

    @Test func aFailingStoreStopsEverySourceItStartedAndEndsTheEngine() async throws {
        let root = tempRoot()
        try Data("not a folder".utf8).write(to: root)  // a file where the meetings folder should be
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = ScriptedSource(), system = ScriptedSource(), engine = RecordingEngine()
        let (s, _) = session(mic: mic, system: system, engine: engine, store: MeetingStore(root: root), sink: RecordingSink())

        await #expect(throws: (any Error).self) { try await s.start() }
        #expect(mic.stopCount == 1 && system.stopCount == 1)
        #expect(engine.finishCount == 1)
    }

    @Test func aRenameDuringTheMeetingSurvivesMuteAndStop() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let source = ScriptedSource(), engine = RecordingEngine(), sink = RecordingSink()
        let (s, meeting) = session(mic: source, engine: engine, store: store, sink: sink)
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
