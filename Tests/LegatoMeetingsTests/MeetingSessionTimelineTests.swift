import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// Both streams, their recordings and their segments share one origin: the moment the first source started.
@Suite struct MeetingSessionTimelineTests {
    struct Rig {
        let root = tempRoot()
        let store: MeetingStore
        let sink = RecordingSink()
        let clock = TestClock()
        let micSource: ScriptedSource, systemSource: ScriptedSource
        let micEngine = RecordingEngine(id: "mic-engine"), systemEngine = RecordingEngine(id: "sys-engine")
        let meeting = Meeting(title: "Timeline", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let session: MeetingSession

        /// - Parameters:
        ///   - origin: where the test clock stands when the meeting is started (the clock's origin is arbitrary).
        ///   - systemStartTakes: how long the system source takes to start, e.g. a permission prompt.
        init(origin: TimeInterval = 0, systemStartTakes: TimeInterval = 0, locale: Locale? = nil) {
            let clock = self.clock
            clock.now = origin
            store = MeetingStore(root: root)
            micSource = ScriptedSource()
            systemSource = ScriptedSource(onStart: { clock.now += systemStartTakes })
            session = MeetingSession(
                meeting: meeting,
                inputs: [
                    MeetingInput(stream: .mic, source: micSource, engine: micEngine, locale: locale),
                    MeetingInput(stream: .system, source: systemSource, engine: systemEngine, locale: locale),
                ],
                store: store, sink: sink, convert: { $0 }, clock: { clock.now })
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func stored() async -> [MeetingSegment] { (try? await store.segments(for: meeting.id)) ?? [] }
    }

    @Test func aLateStartingStreamGetsLeadingSilenceAndItsSegmentsLineUp() async throws {
        let rig = Rig(systemStartTakes: 0.5)
        defer { rig.cleanup() }
        try await rig.session.start()

        // The same second of speech in both engines' own time: the system stream began 0.5 s later.
        rig.micEngine.emit(finalEvent("Same words.", 1..<2))
        rig.systemEngine.emit(finalEvent("Same words.", 1..<2))
        #expect(await eventually { await rig.stored().count == 2 })
        let byStream = Dictionary(uniqueKeysWithValues: await rig.stored().map { ($0.stream, $0) })
        #expect(byStream[.mic]?.start == 1 && byStream[.mic]?.end == 2)
        #expect(byStream[.system]?.start == 1.5 && byStream[.system]?.end == 2.5)

        // The recording of the late stream starts with the lead, before any audio.
        rig.systemSource.push(tone(1_600))
        #expect(await eventually { rig.sink.calls.count == 2 })
        #expect(rig.sink.calls == [.silence(.system, 0.5), .write(.system, Array(repeating: 0.5, count: 1_600))])
        _ = await rig.session.stop()
    }

    @Test func theFirstSourceToStartSetsTheOriginAndClockTimesAreMeasuredFromIt() async throws {
        // A clock whose origin is far from zero, and a start that takes 2 s before the first source is up.
        let rig = Rig(origin: 5_000, systemStartTakes: 2)
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.session.elapsed == 2)  // the mic started at 5000, the system source finished at 5002

        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        rig.clock.now = 5_007
        rig.micEngine.emit(TranscriptEvent(stream: .mic, text: "Thinking", isFinal: false))
        #expect(await eventually { latest.withLock { $0 }?.volatile[.mic] == "Thinking" })  // heard at the clock time, whatever the load
        rig.clock.now = 5_008
        rig.micEngine.emit(finalEvent("Thinking aloud."))
        #expect(await eventually { await rig.stored().count == 1 })
        let seg = try #require(await rig.stored().first)
        #expect(seg.start == 7 && seg.end == 8)

        rig.clock.now = 5_010
        await rig.session.setMuted(true, stream: .mic)
        rig.clock.now = 5_012
        let finished = await rig.session.stop()
        #expect(finished.mutedRanges == [MutedRange(stream: .mic, start: 10, end: 12)])
        #expect(finished.duration == 12)
    }

    @Test func aRestartedSourceHasItsGapFilledWithSilence() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micSource.push(tone(16_000))  // 1 s of audio
        #expect(await eventually { rig.sink.calls.count == 1 })
        rig.clock.now = 5  // 4 s pass with nothing from the mic, then it comes back
        rig.micSource.resume()

        #expect(await eventually { rig.sink.calls.count == 2 })
        #expect(rig.sink.calls[1] == .silence(.mic, 4))
        // The engine's own timeline stays in step with the recording.
        #expect(await eventually { rig.micEngine.chunks.reduce(0) { $0 + $1.samples.count } == 5 * 16_000 })
        #expect(rig.micEngine.chunks.dropFirst().allSatisfy { $0.samples.allSatisfy { $0 == 0 } })

        // Jitter is not a gap.
        rig.clock.now = 5.1
        rig.micSource.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.sink.calls.count == 2)
        _ = await rig.session.stop()
    }

    @Test func enginesArePreparedForTheInputsLocale() async throws {
        let rig = Rig(locale: Locale(identifier: "de-DE"))
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.micEngine.preparedLocales == [Locale(identifier: "de-DE")])
        #expect(rig.systemEngine.preparedLocales == [Locale(identifier: "de-DE")])
        _ = await rig.session.stop()
    }

    @Test func noLocaleMeansTheEngineChooses() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.micEngine.preparedLocales == [nil])
        _ = await rig.session.stop()
    }
}
