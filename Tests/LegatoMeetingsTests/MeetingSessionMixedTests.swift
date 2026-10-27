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
        let diarizer: FakeDiarizer?
        let meeting = Meeting(title: "Mixed", date: Date(timeIntervalSince1970: 1), engineID: "fake")
        let session: MeetingSession

        init(sources: Int = 2, diarizer: FakeDiarizer? = nil, enrollment: [Float]? = nil, locale: Locale? = nil) {
            store = MeetingStore(root: root)
            self.diarizer = diarizer
            var inputs = [MeetingSource(stream: .mic, source: micSource)]
            if sources > 1 { inputs.append(MeetingSource(stream: .system, source: systemSource)) }
            session = MeetingSession(
                meeting: meeting, sources: inputs, engine: engine, locale: locale, diarizer: diarizer, enrollment: enrollment,
                store: store, sink: sink, convert: { $0 }, clock: { [clock] in clock.now })
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

    @Test func discardWorksOnTheTwoEnginePathToo() async throws {
        let rig = MeetingSessionTests.Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        await rig.session.discard()
        #expect(try await rig.store.meeting(id: rig.meeting.id) == nil)
        #expect(rig.micSource.stopCount == 1)
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
        #expect(await eventually {
            (try? await rig.store.liveTurns(for: rig.meeting.id)) == [
                SpeakerTurn(speaker: "P1", start: 0, end: 9), SpeakerTurn(speaker: "P2", start: 9, end: 12),
            ]
        })
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
        rig.micSource.push(tone(1_600))
        #expect(await eventually { await rig.stored().last?.speaker == "P1" })
        #expect(await rig.stored().first?.speaker == nil, "older than 3 s: left as it was")
        _ = await rig.session.stop()
    }

    @Test func theEnrolledSlotIsYou() async throws {
        let diarizer = FakeDiarizer(enrolledSlot: "slotY")
        let rig = Rig(diarizer: diarizer, enrollment: [0.1, 0.2, 0.3])
        defer { rig.cleanup() }
        try await rig.session.start()
        #expect(diarizer.enrolled == [[0.1, 0.2, 0.3]])
        diarizer.script([SpeakerTurn(speaker: "other", start: 0, end: 3), SpeakerTurn(speaker: "slotY", start: 3, end: 6)])
        rig.clock.now = 6
        rig.micSource.push(tone(1_600))
        rig.engine.emit(finalEvent("Me talking.", 3.5..<5))
        #expect(await eventually { await rig.stored().first?.speaker != nil })
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.speakers.values.contains { $0.isYou } == true })
        let saved = try #require(try await rig.store.meeting(id: rig.meeting.id))
        let you = saved.speakers.filter { $0.value.isYou }
        #expect(you.count == 1 && you.first?.value.name == "You")
        #expect(await rig.stored().first?.speaker == you.first?.key)
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
