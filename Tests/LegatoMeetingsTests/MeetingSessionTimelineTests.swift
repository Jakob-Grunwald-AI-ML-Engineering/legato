import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// Every recording and every segment share one origin: the moment the first source started. Ported from the
/// two-engine session to the mixed one.
@Suite struct MeetingSessionTimelineTests {
    struct Rig {
        let root = tempRoot()
        let store: MeetingStore
        let sink = RecordingSink()
        let clock = TestClock()
        let micSource: ScriptedSource, systemSource: ScriptedSource
        let engine = RecordingEngine(id: "mixed-engine")
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
                sources: [MeetingSource(stream: .mic, source: micSource), MeetingSource(stream: .system, source: systemSource)],
                engine: engine, locale: locale, store: store, sink: sink, convert: { $0 }, clock: { clock.now })
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func stored() async -> [MeetingSegment] { (try? await store.segments(for: meeting.id)) ?? [] }
        func calls(_ stream: TranscriptEvent.Stream) -> [RecordingSink.Call] {
            sink.calls.filter {
                switch $0 {
                case .write(let s, _), .silence(let s, _): s == stream
                case .finish: false
                }
            }
        }
    }

    @Test func aLateStartingSourcesTrackBeginsWithItsLeadAndTheEnginesTimesNeedNoOffset() async throws {
        let rig = Rig(systemStartTakes: 0.5)
        defer { rig.cleanup() }
        try await rig.session.start()

        // The engine hears the mix from the meeting's first moment: its times are meeting times.
        rig.engine.emit(finalEvent("Same words.", 1..<2))
        #expect(await eventually { await rig.stored().count == 1 })
        let segment = try #require(await rig.stored().first)
        #expect(segment.start == 1 && segment.end == 2)

        // The recording of the late source starts with the lead, before any audio.
        rig.systemSource.push(tone(1_600))
        #expect(await eventually { rig.calls(.system).count == 2 })
        #expect(rig.calls(.system) == [.silence(.system, 0.5), .write(.system, Array(repeating: 0.5, count: 1_600))])
        _ = await rig.session.stop()
    }

    @Test func theFirstSourceToStartSetsTheOriginAndClockTimesAreMeasuredFromIt() async throws {
        // A clock whose origin is far from zero, and a start that takes 2 s before the second source is up.
        let rig = Rig(origin: 5_000, systemStartTakes: 2)
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.session.elapsed == 2)  // the mic started at 5000, the system source finished at 5002

        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        rig.clock.now = 5_007
        rig.engine.emit(TranscriptEvent(stream: .mic, text: "Thinking", isFinal: false))
        #expect(await eventually { latest.withLock { $0 }?.volatile[.mixed] == "Thinking" })  // heard at 7, whatever the load
        rig.clock.now = 5_008
        rig.engine.emit(finalEvent("Thinking aloud."))
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

    @Test func aRestartedSourceHasItsGapFilledWithSilenceButJitterIsNotAGap() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()

        rig.micSource.push(tone(16_000))  // 1 s of audio
        #expect(await eventually { rig.calls(.mic).count == 1 })
        rig.clock.now = 5  // 4 s pass with nothing from the mic, then it comes back
        rig.micSource.resume()

        #expect(await eventually { rig.calls(.mic).count == 2 })
        #expect(rig.calls(.mic)[1] == .silence(.mic, 4))

        // Jitter is not a gap.
        rig.clock.now = 5.1
        await rig.session.fillGap(stream: .mic)
        #expect(rig.calls(.mic).count == 2)
        _ = await rig.session.stop()
    }

    @Test func theEngineIsPreparedForTheMeetingsLocale() async throws {
        let rig = Rig(locale: Locale(identifier: "de-DE"))
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.engine.preparedLocales == [Locale(identifier: "de-DE")])
        _ = await rig.session.stop()
    }

    @Test func noLocaleMeansTheEngineChooses() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.engine.preparedLocales == [nil])
        _ = await rig.session.stop()
    }
}
