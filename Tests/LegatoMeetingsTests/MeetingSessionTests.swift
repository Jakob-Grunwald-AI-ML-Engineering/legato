import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// The basics of a session: segments, timing, mute, conversion, stop and snapshots. Ported from the two-engine
/// session to the mixed one (one engine on the mix of every source).
@Suite struct MeetingSessionTests {
    struct Rig {
        let root = tempRoot()
        let store: MeetingStore
        let sink = RecordingSink()
        let clock = TestClock()
        let micSource = ScriptedSource(), systemSource = ScriptedSource()
        let engine = RecordingEngine(id: "mixed-engine")
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let session: MeetingSession

        init(convert: @escaping MeetingAudioConverter = { $0 }) {
            store = MeetingStore(root: root)
            session = MeetingSession(
                meeting: meeting,
                sources: [MeetingSource(stream: .mic, source: micSource), MeetingSource(stream: .system, source: systemSource)],
                engine: engine, store: store, sink: sink, convert: convert, clock: { [clock] in clock.now })
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func stored() async -> [MeetingSegment] { (try? await store.segments(for: meeting.id)) ?? [] }
        /// What the sink got for `stream`'s own track.
        func calls(_ stream: TranscriptEvent.Stream) -> [RecordingSink.Call] {
            sink.calls.filter {
                switch $0 {
                case .write(let s, _), .silence(let s, _): s == stream
                case .finish: false
                }
            }
        }
    }

    @Test func segmentsAreSavedAsTheyArriveInTimeOrderAndSurviveAReopenedStore() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        // Apple Speech tags every event `.mic`; the session tags what the mix engine says `.mixed`.
        rig.engine.emit(finalEvent("My point.", 5..<6))
        rig.engine.emit(finalEvent("Their point.", 2..<3, stream: .mic))

        #expect(await eventually { await rig.stored().count == 2 })
        let segments = await rig.stored()
        #expect(segments.map(\.text) == ["Their point.", "My point."])
        #expect(segments.map(\.stream) == [.mixed, .mixed])
        #expect(segments.map(\.start) == [2, 5])
        #expect(segments.map(\.end) == [3, 6])
        #expect(segments.allSatisfy { $0.origin == .live && !$0.echo })

        // The store reopened mid-meeting still has them.
        let reopened = MeetingStore(root: rig.root)
        #expect(try await reopened.segments(for: rig.meeting.id) == segments)
        _ = await rig.session.stop()
    }

    @Test func aSegmentWithoutARangeIsTimedByTheClock() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        try await rig.session.start()

        rig.clock.now = 7
        rig.engine.emit(TranscriptEvent(stream: .mic, text: "Thinking", isFinal: false))
        #expect(await eventually { latest.withLock { $0 }?.volatile[.mixed] == "Thinking" })  // heard at 7, whatever the load
        rig.clock.now = 8
        rig.engine.emit(finalEvent("Thinking aloud."))

        #expect(await eventually { await rig.stored().count == 1 })
        let seg = try #require(await rig.stored().first)
        #expect(seg.start == 7)
        #expect(seg.end == 8)
        _ = await rig.session.stop()
    }

    @Test func aMutedStreamIsRecordedAsSilenceAndItsRangeIsKept() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micSource.push(tone(1_600))  // 0.1 s while live
        #expect(await eventually { rig.calls(.mic).count == 1 })

        rig.clock.now = 10
        await rig.session.setMuted(true, stream: .mic)
        rig.micSource.push(tone(1_600))
        #expect(await eventually { rig.calls(.mic).count == 2 })

        // The sink records silence of the same length instead of the voice.
        #expect(rig.calls(.mic) == [.write(.mic, Array(repeating: 0.5, count: 1_600)), .silence(.mic, 0.1)])

        rig.clock.now = 12
        await rig.session.setMuted(false, stream: .mic)
        rig.clock.now = 13
        let finished = await rig.session.stop()

        #expect(finished.mutedRanges == [MutedRange(stream: .mic, start: 10, end: 12)])
        #expect(try await rig.store.meeting(id: rig.meeting.id)?.mutedRanges == finished.mutedRanges)
    }

    @Test func muteAppliesOnlyToItsOwnStream() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.session.setMuted(true, stream: .mic)

        rig.systemSource.push(tone(800))
        #expect(await eventually { rig.calls(.system).count == 1 })
        #expect(rig.calls(.system) == [.write(.system, Array(repeating: 0.5, count: 800))])
        _ = await rig.session.stop()
    }

    @Test func aMuteStillOpenAtStopIsClosedAtTheStopTime() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 4
        await rig.session.setMuted(true, stream: .mic)
        rig.clock.now = 9
        let finished = await rig.session.stop()
        #expect(finished.mutedRanges == [MutedRange(stream: .mic, start: 4, end: 9)])
    }

    @Test func theSinkGetsConvertedAudioAndTheEngineGetsTheMixInItsOwnFormat() async throws {
        let rig = Rig(convert: { AudioChunk(samples: $0.samples.map { $0 * 2 }, format: $0.format) })
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micSource.push(tone(1_600, 0.25))
        #expect(await eventually { rig.calls(.mic).count == 1 })
        #expect(rig.calls(.mic) == [.write(.mic, Array(repeating: 0.5, count: 1_600))])
        rig.clock.now = 0.1
        _ = await rig.session.stop()
        #expect(rig.engine.chunks.flatMap(\.samples) == Array(repeating: 0.25, count: 1_600))
    }

    @Test func stopFinishesEverythingAndMovesTheMeetingToProcessing() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 61
        let finished = await rig.session.stop()

        #expect(finished.state == .processing)
        #expect(finished.duration == 61)
        #expect(try await rig.store.meeting(id: rig.meeting.id) == finished)
        #expect(rig.sink.calls.last == .finish)
        #expect(rig.micSource.stopCount == 1 && rig.systemSource.stopCount == 1)
        #expect(rig.engine.finishCount == 1)
    }

    @Test func startPersistsTheMeetingAsRecording() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(try await rig.store.meeting(id: rig.meeting.id)?.state == .recording)
        _ = await rig.session.stop()
    }

    @Test func snapshotsReportSegmentsVolatileTextAndMute() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        try await rig.session.start()
        rig.engine.emit(TranscriptEvent(stream: .mic, text: "Hel", isFinal: false))
        await rig.session.setMuted(true, stream: .mic)

        #expect(await eventually {
            let s = latest.withLock { $0 }
            return s?.volatile[.mixed] == "Hel" && s?.mutedStreams == [.mic]
        })
        _ = await rig.session.stop()
    }
}
