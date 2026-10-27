import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingSessionTests {
    struct Rig {
        let root = tempRoot()
        let store: MeetingStore
        let sink = RecordingSink()
        let clock = TestClock()
        let micSource = ScriptedSource(), systemSource = ScriptedSource()
        let micEngine = RecordingEngine(id: "mic-engine"), systemEngine = RecordingEngine(id: "sys-engine")
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let session: MeetingSession

        init(convert: @escaping MeetingAudioConverter = { $0 }) {
            store = MeetingStore(root: root)
            session = MeetingSession(
                meeting: meeting,
                inputs: [
                    MeetingInput(stream: .mic, source: micSource, engine: micEngine),
                    MeetingInput(stream: .system, source: systemSource, engine: systemEngine),
                ],
                store: store, sink: sink, convert: convert, clock: { [clock] in clock.now })
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func stored() async -> [MeetingSegment] { (try? await store.segments(for: meeting.id)) ?? [] }
    }

    @Test func twoStreamsProduceOrderedRetaggedSegments() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        // Apple Speech tags every event `.mic`; the session re-tags by the input the event came from.
        rig.micEngine.emit(finalEvent("My point.", 5..<6))
        rig.systemEngine.emit(finalEvent("Their point.", 2..<3, stream: .mic))

        #expect(await eventually { await rig.stored().count == 2 })
        let segments = await rig.stored()
        #expect(segments.map(\.text) == ["Their point.", "My point."])
        #expect(segments.map(\.stream) == [.system, .mic])
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
        try await rig.session.start()

        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        rig.clock.now = 7
        rig.micEngine.emit(TranscriptEvent(stream: .mic, text: "Thinking", isFinal: false))
        #expect(await eventually { latest.withLock { $0 }?.volatile[.mic] == "Thinking" })  // heard at the clock time, whatever the load
        rig.clock.now = 8
        rig.micEngine.emit(finalEvent("Thinking aloud."))

        #expect(await eventually { await rig.stored().count == 1 })
        let seg = try #require(await rig.stored().first)
        #expect(seg.start == 7)
        #expect(seg.end == 8)
        _ = await rig.session.stop()
    }

    @Test func aMutedStreamFeedsSilenceToEngineAndSinkAndRecordsTheRange() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micSource.push(tone(1_600))  // 0.1 s while live
        #expect(await eventually { rig.micEngine.chunks.count == 1 })

        rig.clock.now = 10
        await rig.session.setMuted(true, stream: .mic)
        rig.micSource.push(tone(1_600))
        #expect(await eventually { rig.micEngine.chunks.count == 2 })

        // Silence of the same size reaches the engine, and the sink records silence instead of the voice.
        #expect(rig.micEngine.chunks[0].samples == Array(repeating: 0.5, count: 1_600))
        #expect(rig.micEngine.chunks[1].samples == Array(repeating: 0, count: 1_600))
        #expect(rig.sink.calls == [.write(.mic, Array(repeating: 0.5, count: 1_600)), .silence(.mic, 0.1)])

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
        #expect(await eventually { rig.systemEngine.chunks.count == 1 })
        #expect(rig.systemEngine.chunks[0].samples == Array(repeating: 0.5, count: 800))
        #expect(rig.sink.calls == [.write(.system, Array(repeating: 0.5, count: 800))])
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

    @Test func theSinkGetsConvertedAudioAndTheEngineGetsTheSourceFormat() async throws {
        let rig = Rig(convert: { AudioChunk(samples: $0.samples.map { $0 * 2 }, format: $0.format) })
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micSource.push(tone(100, 0.25))
        #expect(await eventually { rig.micEngine.chunks.count == 1 && rig.sink.calls.count == 1 })
        #expect(rig.micEngine.chunks[0].samples == Array(repeating: 0.25, count: 100))
        #expect(rig.sink.calls == [.write(.mic, Array(repeating: 0.5, count: 100))])
        _ = await rig.session.stop()
    }

    @Test func anEchoIsMarkedAndAMicSegmentWithOtherWordsIsKept() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.systemEngine.emit(finalEvent("the quarterly numbers look good", 10..<13))
        #expect(await eventually { await rig.stored().count == 1 })
        rig.micEngine.emit(finalEvent("The quarterly numbers look good.", 10.5..<13.5))
        rig.micEngine.emit(finalEvent("I disagree with that plan", 20..<22))

        #expect(await eventually { await rig.stored().count == 3 })
        let byText = Dictionary(uniqueKeysWithValues: await rig.stored().map { ($0.text, $0) })
        #expect(byText["The quarterly numbers look good."]?.echo == true)
        #expect(byText["I disagree with that plan"]?.echo == false)
        #expect(byText["the quarterly numbers look good"]?.echo == false)
        _ = await rig.session.stop()
    }

    @Test func aLateSystemSegmentMarksTheMicSegmentThatWasAlreadySaved() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micEngine.emit(finalEvent("the quarterly numbers look good", 10.5..<13.5))
        #expect(await eventually { await rig.stored().count == 1 })
        rig.systemEngine.emit(finalEvent("the quarterly numbers look good", 10..<13))

        #expect(await eventually { await rig.stored().count == 2 })
        #expect(await eventually { await rig.stored().first { $0.stream == .mic }?.echo == true })
        _ = await rig.session.stop()
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
        #expect(rig.micEngine.finishCount == 1 && rig.systemEngine.finishCount == 1)
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
        rig.micEngine.emit(TranscriptEvent(stream: .mic, text: "Hel", isFinal: false))
        await rig.session.setMuted(true, stream: .mic)

        #expect(await eventually {
            let s = latest.withLock { $0 }
            return s?.volatile[.mic] == "Hel" && s?.mutedStreams == [.mic]
        })
        _ = await rig.session.stop()
    }
}
