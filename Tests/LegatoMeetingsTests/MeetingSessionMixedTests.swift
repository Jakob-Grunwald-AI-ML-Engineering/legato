import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// Several sources, one mixer, one engine; plus pause, discard and the diarizer hook.
@Suite struct MeetingSessionMixedTests {
    struct Rig {
        let root = tempRoot()
        let store: MeetingStore
        let sink = RecordingSink()
        let clock = TestClock()
        let micSource = ScriptedSource(), systemSource = ScriptedSource()
        let engine = RecordingEngine(id: "mixed-engine")
        let diarizer: (any SpeakerDiarizer)?
        let meeting = Meeting(title: "Mixed", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let session: MeetingSession

        init(sources: Int = 2, diarizer: (any SpeakerDiarizer)? = nil, locale: Locale? = nil, feedCapacity: Int = 1_500) {
            store = MeetingStore(root: root)
            self.diarizer = diarizer
            var inputs = [MeetingSource(stream: .mic, source: micSource)]
            if sources > 1 { inputs.append(MeetingSource(stream: .system, source: systemSource)) }
            session = MeetingSession(
                meeting: meeting, sources: inputs, engine: engine, locale: locale, diarizer: diarizer,
                store: store, sink: sink, convert: { $0 }, clock: { [clock] in clock.now }, feedCapacity: feedCapacity)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// The sources are heard for `seconds`, the way live sources deliver: a 100 ms chunk per step, the clock
        /// moving along. Each chunk is taken in before the clock moves again.
        func hear(_ seconds: Double, mic: Float? = nil, system: Float? = nil) async {
            var target = ownTrackCalls
            for _ in 0..<Int((seconds * 10).rounded()) {
                clock.now = ((clock.now + 0.1) * 1000).rounded() / 1000  // no float drift
                if let mic { micSource.push(tone(1_600, mic)); target += 1 }
                if let system { systemSource.push(tone(1_600, system)); target += 1 }
                let wanted = target
                _ = await eventually { ownTrackCalls >= wanted }  // taken in at this time, before the clock moves on
            }
        }

        func stored() async -> [MeetingSegment] { (try? await store.segments(for: meeting.id)) ?? [] }
        /// Calls the sources' own tracks received (not the mix's).
        var ownTrackCalls: Int {
            sink.calls.filter { if case .write(.mixed, _) = $0 { false } else { true } }.count
        }
        var engineSamples: [Float] { engine.chunks.flatMap(\.samples) }
        var mixWrites: [Float] {
            sink.calls.flatMap { call -> [Float] in
                if case .write(.mixed, let samples) = call { return samples }
                return []
            }
        }
    }

    // MARK: One engine on the mix

    @Test func oneEngineGetsTheSumOfBothSourcesAndIsPreparedOnce() async throws {
        let rig = Rig(locale: Locale(identifier: "de-DE"))
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(rig.engine.preparedLocales == [Locale(identifier: "de-DE")])

        await rig.hear(0.5, mic: 0.2, system: 0.3)
        rig.clock.now = 0.7  // the mix runs a little behind the clock, so 0.5 s are due
        #expect(await eventually { rig.engineSamples.count >= 8_000 })
        #expect(rig.engineSamples.prefix(8_000).allSatisfy { abs($0 - 0.5) < 1e-5 })
        _ = await rig.session.stop()
    }

    @Test func segmentsAreTaggedMixedAndKeepTheEnginesTimes() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.engine.emit(finalEvent("Both of us.", 5..<6, stream: .mic))
        rig.engine.emit(finalEvent("And again.", 2..<3, stream: .system))
        #expect(await eventually { await rig.stored().count == 2 })
        let segments = await rig.stored()
        #expect(segments.map(\.stream) == [.mixed, .mixed])
        #expect(segments.map(\.start) == [2, 5])
        #expect(segments.map(\.end) == [3, 6])
        #expect(segments.allSatisfy { !$0.echo })
        _ = await rig.session.stop()
    }

    @Test func aSourceThatNeverDeliversDoesNotHoldTheMixUp() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.hear(1, mic: 0.4)  // the system source says nothing at all
        rig.clock.now = 1.2
        #expect(await eventually { rig.engineSamples.count >= 16_000 })
        #expect(rig.engineSamples.prefix(16_000).allSatisfy { abs($0 - 0.4) < 1e-5 })
        _ = await rig.session.stop()
    }

    @Test func theMixIsAsLongAsTheMeetingWhenItStops() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.micSource.push(tone(8_000))
        rig.clock.now = 2.05
        let finished = await rig.session.stop()
        #expect(finished.duration == 2.05)
        #expect(rig.engineSamples.count == 32_800)  // 2.05 s at 16 kHz, partial last frame included
        #expect(rig.mixWrites.count == 32_800)
        #expect(rig.sink.calls.last == .finish)
    }

    @Test func eachSourceKeepsItsOwnTrackAndTheMixGetsItsOwnWhenThereAreSeveral() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.micSource.push(tone(1_600, 0.2))
        rig.systemSource.push(tone(1_600, 0.3))
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.2, count: 1_600))) })
        #expect(await eventually { rig.sink.calls.contains(.write(.system, Array(repeating: 0.3, count: 1_600))) })
        rig.clock.now = 1
        _ = await rig.session.stop()
        #expect(rig.mixWrites.count == 16_000)
    }

    @Test func aSingleSourceIsItsOwnMixSoNoSeparateMixTrackIsWritten() async throws {
        let rig = Rig(sources: 1)
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.micSource.push(tone(1_600, 0.2))
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.2, count: 1_600))) })
        rig.clock.now = 1
        _ = await rig.session.stop()
        #expect(rig.mixWrites.isEmpty)
        #expect(rig.engineSamples.count == 16_000, "the engine still hears the mix")
    }

    @Test func aLateStartingSourceKeepsItsLeadingSilenceOnItsOwnTrack() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let clock = rig.clock
        let late = ScriptedSource(onStart: { clock.now += 0.5 })
        let session = MeetingSession(
            meeting: rig.meeting, sources: [MeetingSource(stream: .mic, source: rig.micSource), MeetingSource(stream: .system, source: late)],
            engine: rig.engine, store: rig.store, sink: rig.sink, convert: { $0 }, clock: { clock.now })
        try await session.start()
        late.push(tone(1_600))
        #expect(await eventually { rig.sink.calls.contains(.write(.system, Array(repeating: 0.5, count: 1_600))) })
        #expect(rig.sink.calls.contains(.silence(.system, 0.5)))
        _ = await session.stop()
    }

    @Test func aRestartedSourceHasItsOwnTrackFilledAndTheMixSimplyHasSilenceThere() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.micSource.push(tone(16_000))
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.5, count: 16_000))) })
        rig.clock.now = 5
        rig.micSource.resume()
        #expect(await eventually { rig.sink.calls.contains(.silence(.mic, 4)) })
        let finished = await rig.session.stop()
        #expect(finished.duration == 5)
        #expect(rig.engineSamples.count == 80_000)
    }

    @Test func aMicBacklogThatArrivesAtOnceAfterASlowStartIsMixedWhereItWasHeard() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let clock = rig.clock, mic = rig.micSource
        // The system tap takes a second to start; the mic's first second arrives at once when it is up.
        let slowTap = ScriptedSource(onStart: {
            clock.now += 1
            for _ in 0..<10 { mic.push(tone(1_600, 0.2)) }
        })
        let session = MeetingSession(
            meeting: rig.meeting,
            sources: [MeetingSource(stream: .mic, source: mic), MeetingSource(stream: .system, source: slowTap)],
            engine: rig.engine, store: rig.store, sink: rig.sink, convert: { $0 }, clock: { clock.now })
        try await session.start()
        let ownWrites: @Sendable () -> Int = { rig.sink.calls.filter { if case .write(.mixed, _) = $0 { false } else if case .write = $0 { true } else { false } }.count }
        _ = await eventually { ownWrites() == 10 }
        for step in 11...30 {
            let wanted = ownWrites() + 2
            clock.now = Double(step) / 10
            mic.push(tone(1_600, 0.2))
            slowTap.push(tone(1_600, 0.3))
            _ = await eventually { ownWrites() >= wanted }
        }
        let finished = await session.stop()
        #expect(finished.duration == 3)
        let mix = rig.mixWrites
        try #require(mix.count == 48_000, "the mix is as long as the meeting")
        #expect(mix[..<16_000].allSatisfy { abs($0 - 0.2) < 1e-5 }, "the backlog is in the first second, where it was heard")
        #expect(mix[16_000...].allSatisfy { abs($0 - 0.5) < 1e-5 }, "and the mic stays audible next to the system audio")
    }

    @Test func theMixEndsAtTheStopEvenWhenStoppingTheSourcesTakesAWhile() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let slow = SlowStopSource(clock: rig.clock)
        let session = MeetingSession(
            meeting: rig.meeting,
            sources: [MeetingSource(stream: .mic, source: rig.micSource), MeetingSource(stream: .system, source: slow)],
            engine: rig.engine, store: rig.store, sink: rig.sink, convert: { $0 }, clock: { [clock = rig.clock] in clock.now })
        try await session.start()
        rig.micSource.push(tone(8_000))
        rig.clock.now = 2
        let finished = await session.stop()  // the tap takes 300 ms (and a clock second) to stop
        #expect(finished.duration == 2)
        #expect(rig.engineSamples.count == 32_000, "the mix is as long as the meeting, not as long as the stop took")
        #expect(rig.mixWrites.count == 32_000)
    }

    // MARK: Mute and pause

    @Test func aMutedSourceIsSilentInTheMixButTheOtherIsNot() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.session.setMuted(true, stream: .mic)
        await rig.hear(0.5, mic: 0.2, system: 0.3)
        rig.clock.now = 0.7
        #expect(await eventually { rig.engineSamples.count >= 8_000 })
        #expect(rig.engineSamples.prefix(8_000).allSatisfy { abs($0 - 0.3) < 1e-5 })
        #expect(rig.sink.calls.contains(.silence(.mic, 0.1)))
        _ = await rig.session.stop()
    }

    @Test func pauseSilencesEverythingAndIsOneRangeSeparateFromMute() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.hear(1, mic: 0.5)  // the first second, heard by the mic only

        await rig.session.pause()
        await rig.session.pause()  // already paused: nothing happens
        await rig.hear(0.5, mic: 0.5, system: 0.5)
        let silences = rig.sink.calls.filter { if case .silence = $0 { true } else { false } }
        #expect(silences.count == 10, "every chunk heard while paused is recorded as silence")

        rig.clock.now = 2
        await rig.session.resume()
        rig.clock.now = 3
        let finished = await rig.session.stop()

        #expect(finished.pausedRanges == [PausedRange(start: 1, end: 2)])
        #expect(finished.mutedRanges.isEmpty)
        let mix = rig.engineSamples
        #expect(mix.count == 48_000)
        #expect(mix[..<16_000].allSatisfy { abs($0 - 0.5) < 1e-5 })
        #expect(mix[16_000...].allSatisfy { $0 == 0 })
        #expect(try await rig.store.meeting(id: rig.meeting.id)?.pausedRanges == finished.pausedRanges)
    }

    @Test func aPauseStillOpenAtStopIsClosedAtTheStopTime() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 4
        await rig.session.pause()
        rig.clock.now = 9
        let finished = await rig.session.stop()
        #expect(finished.pausedRanges == [PausedRange(start: 4, end: 9)])
    }

    @Test func aMuteAfterTheStopRecordsNoRangePastTheEnd() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 2
        _ = await rig.session.stop()
        rig.clock.now = 5
        await rig.session.setMuted(true, stream: .mic)
        rig.clock.now = 6
        await rig.session.setMuted(false, stream: .mic)
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await rig.store.meeting(id: rig.meeting.id)?.mutedRanges.isEmpty == true)
    }

    @Test func theSnapshotSaysWhetherTheMeetingIsPaused() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        try await rig.session.start()
        await rig.session.pause()
        #expect(await eventually { latest.withLock { $0 }?.isPaused == true })
        await rig.session.resume()
        #expect(await eventually { latest.withLock { $0 }?.isPaused == false })
        _ = await rig.session.stop()
    }

    // MARK: Discard

    @Test func discardStopsTheCaptureAndRemovesTheMeetingFolder() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.micSource.push(tone(1_600))
        rig.engine.emit(finalEvent("Not for the record.", 1..<2))
        #expect(await eventually { await rig.stored().count == 1 })
        let folder = await rig.store.folder(for: rig.meeting.id)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        await rig.session.discard()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await rig.store.meeting(id: rig.meeting.id) == nil)
        #expect(rig.micSource.stopCount == 1 && rig.systemSource.stopCount == 1)
        #expect(rig.engine.finishCount == 1)

        // Nothing brings it back, not even a late stop.
        _ = await rig.session.stop()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func discardEndsTheSnapshotStream() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        let snapshots = rig.session.snapshots
        let ended = Task { for await _ in snapshots {}; return true }
        await rig.session.discard()
        #expect(await ended.value)
    }

    // MARK: Diarizer hook

    @Test func theDiarizerIsFedTheMix() async throws {
        let diarizer = FakeDiarizer()
        let rig = Rig(diarizer: diarizer)
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.hear(0.5, mic: 0.2, system: 0.3)
        rig.clock.now = 0.7
        #expect(await eventually { diarizer.fedSamples >= 8_000 })
        #expect(diarizer.fed.prefix(5).allSatisfy { $0.samples.allSatisfy { abs($0 - 0.5) < 1e-5 } })
        _ = await rig.session.stop()
        #expect(diarizer.finishCount == 1)
    }

    @Test func turnsBecomePeopleSegmentsGetThemAndBothArePersisted() async throws {
        let diarizer = FakeDiarizer()
        let rig = Rig(diarizer: diarizer)
        defer { rig.cleanup() }
        try await rig.session.start()
        diarizer.script([SpeakerTurn(speaker: "c0", start: 0, end: 9), SpeakerTurn(speaker: "c1", start: 9, end: 12)])
        rig.clock.now = 10
        rig.micSource.push(tone(1_600))  // a feed round makes the session read the turns
        rig.engine.emit(finalEvent("First voice.", 7.5..<8.5))
        rig.engine.emit(finalEvent("Second voice.", 9.5..<10))

        #expect(await eventually { await rig.stored().map(\.speaker) == ["P1", "P2"] })
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.speakers.count == 2 })
        let saved = try #require(try await rig.store.meeting(id: rig.meeting.id))
        #expect(saved.speakers["P1"]?.name == "Speaker 1" && saved.speakers["P2"]?.name == "Speaker 2")
        #expect(saved.speakers["P1"]?.colorIndex == 0 && saved.speakers["P2"]?.colorIndex == 1)
        // A9: the turns file is append-only; turns still open to revision (the last 3 s) are written at the stop.
        _ = await rig.session.stop()
        #expect(try await rig.store.liveTurns(for: rig.meeting.id) == [
            SpeakerTurn(speaker: "P1", start: 0, end: 9), SpeakerTurn(speaker: "P2", start: 9, end: 12),
        ])
    }

    @Test func aTurnIsWrittenOnceWhenItHasSettledAndTheRestAtTheStop() async throws {
        let diarizer = FakeDiarizer()
        let rig = Rig(diarizer: diarizer)
        defer { rig.cleanup() }
        try await rig.session.start()
        diarizer.script([SpeakerTurn(speaker: "c0", start: 0, end: 2), SpeakerTurn(speaker: "c1", start: 2, end: 9)])
        rig.clock.now = 10  // 0-2 s is older than the 3 s a diarizer may revise; 2-9 s is not
        let settled = [SpeakerTurn(speaker: "P1", start: 0, end: 2)]
        #expect(await eventually { (try? await rig.store.liveTurns(for: rig.meeting.id)) == settled })
        rig.clock.now = 10.5  // more rounds of the diarizer, the same answer
        #expect(await eventually { diarizer.fedSamples >= 103 * 1_600 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await rig.store.liveTurns(for: rig.meeting.id) == settled, "written once, not rewritten")
        _ = await rig.session.stop()
        #expect(try await rig.store.liveTurns(for: rig.meeting.id) == settled + [SpeakerTurn(speaker: "P2", start: 2, end: 9)])
    }

    @Test func framesALaggingDiarizerNeverSawDoNotShiftItsTurns() async throws {
        let diarizer = GatedDiarizer()
        let rig = Rig(diarizer: diarizer, feedCapacity: 5)  // its feed holds one frame
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.hear(1.0, mic: 0.5)
        rig.clock.now = 1.2  // ten frames are due; the diarizer is still in its first
        #expect(await eventually { rig.mixWrites.count >= 16_000 })
        // It saw 0-0.1 s, then (the rest dropped) 0.9-1.0 s: its own 0.1-0.2 s is the meeting's 0.9-1.0 s.
        diarizer.script([SpeakerTurn(speaker: "c0", start: 0.1, end: 0.2)])
        diarizer.open()
        #expect(await eventually { diarizer.fedSamples == 3_200 })
        _ = await rig.session.stop()
        let turns = try await rig.store.liveTurns(for: rig.meeting.id)
        #expect(turns.count == 1)
        #expect(abs((turns.first?.start ?? 0) - 0.9) < 1e-6 && abs((turns.first?.end ?? 0) - 1.0) < 1e-6)
    }

    @Test func snapshotsComeAtMostFourTimesASecond() async throws {
        let rig = Rig(diarizer: FakeDiarizer())
        defer { rig.cleanup() }
        let received = Mutex<(count: Int, last: MeetingSnapshot?)>((0, nil))
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { received.withLock { $0 = ($0.count + 1, s) } } }
        defer { collector.cancel() }
        try await rig.session.start()
        let began = ContinuousClock.now
        received.withLock { $0.count = 0 }
        for i in 0..<100 {  // the engine says something new every 10 ms, the diarizer gets frames
            rig.engine.emit(TranscriptEvent(stream: .mic, text: "word \(i)", isFinal: false))
            rig.clock.now += 0.01
            try await Task.sleep(for: .milliseconds(10))
        }
        let seconds = Double((ContinuousClock.now - began).components.seconds) + 1
        #expect(received.withLock { $0.count } <= Int(4 * seconds) + 2)
        #expect(await eventually { received.withLock { $0.last }?.volatile[.mixed] == "word 99" }, "the newest state still arrives")
        _ = await rig.session.stop()
    }

    @Test func aSegmentHeardBeforeItsTurnArrivesIsRelabelledButOnlyWithinThreeSeconds() async throws {
        let diarizer = FakeDiarizer()
        let rig = Rig(diarizer: diarizer)
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 20
        rig.engine.emit(finalEvent("Long ago.", 1..<2))
        rig.engine.emit(finalEvent("Just now.", 18..<19))
        #expect(await eventually { await rig.stored().count == 2 })
        #expect(await rig.stored().allSatisfy { $0.speaker == nil }, "the diarizer has said nothing yet")

        diarizer.script([SpeakerTurn(speaker: "c0", start: 0, end: 20)])
        rig.clock.now = 20.3  // the next frames of the mix make the session read the turns
        #expect(await eventually { await rig.stored().last?.speaker == "P1" })
        #expect(await rig.stored().first?.speaker == nil, "older than 3 s: left as it was")
        _ = await rig.session.stop()
    }

    @Test func aDiarizerThatFailsIsReportedAndTheRecordingGoesOn() async throws {
        let diarizer = FakeDiarizer()
        diarizer.failFeeds()
        let rig = Rig(diarizer: diarizer)
        defer { rig.cleanup() }
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        try await rig.session.start()
        rig.micSource.push(tone(8_000))
        rig.clock.now = 1
        #expect(await eventually { latest.withLock { $0 }?.diarizerError != nil })
        rig.engine.emit(finalEvent("Still transcribed.", 1..<2))
        #expect(await eventually { await rig.stored().count == 1 })
        let finished = await rig.session.stop()
        #expect(finished.state == .processing)
    }

    @Test func withoutADiarizerSegmentsHaveNoSpeaker() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.engine.emit(finalEvent("Anyone.", 1..<2))
        #expect(await eventually { await rig.stored().count == 1 })
        #expect(await rig.stored().first?.speaker == nil)
        _ = await rig.session.stop()
    }
}

/// A source whose stop takes a while (a system tap's teardown can): the clock moves on meanwhile.
final class SlowStopSource: AudioSource {
    let inner = ScriptedSource()
    let clock: TestClock
    init(clock: TestClock) { self.clock = clock }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { try await inner.start(format: format) }
    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async {
        clock.now += 1
        try? await Task.sleep(for: .milliseconds(300))
        await inner.stop()
    }
}

/// A streaming diarizer that takes its first frame only once the test opens it (one that lags), and answers
/// with the turns it is given.
final class GatedDiarizer: SpeakerDiarizer {
    private let state = Mutex((open: false, fed: 0, turns: [SpeakerTurn]()))
    var fedSamples: Int { state.withLock { $0.fed } }
    func open() { state.withLock { $0.open = true } }
    func script(_ turns: [SpeakerTurn]) { state.withLock { $0.turns = turns } }

    func feed(_ chunk: AudioChunk) async throws {
        while !state.withLock({ $0.open }) { try? await Task.sleep(for: .milliseconds(2)) }
        state.withLock { $0.fed += chunk.samples.count }
    }
    func turns() async -> [SpeakerTurn] { state.withLock { $0.turns } }
    func finish() async throws -> [SpeakerTurn] { state.withLock { $0.turns } }
}
