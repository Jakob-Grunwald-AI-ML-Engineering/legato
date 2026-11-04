import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// Several sources, one mixer, one engine; plus pause, discard, speakers and gaps.
@Suite struct MeetingSessionMixedTests {
    struct Rig {
        let root = tempRoot()
        let store: MeetingStore
        let sink = RecordingSink()
        let clock = TestClock()
        let micSource = ScriptedSource(), systemSource = ScriptedSource()
        let engine = RecordingEngine(id: "mixed-engine")
        let meeting = Meeting(title: "Mixed", date: Date(timeIntervalSince1970: 1))
        let session: MeetingSession

        init(sources: Int = 2, locale: Locale? = nil, feedCapacity: Int = 1_500) {
            store = MeetingStore(root: root)
            var inputs = [MeetingSource(stream: .mic, source: micSource)]
            if sources > 1 { inputs.append(MeetingSource(stream: .system, source: systemSource)) }
            session = MeetingSession(
                meeting: meeting, sources: inputs, engine: engine, locale: locale,
                store: store, sink: sink, clock: { [clock] in clock.now }, feedCapacity: feedCapacity)
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
            engine: rig.engine, store: rig.store, sink: rig.sink, clock: { clock.now })
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

    @Test func aRestartedSourceIsMixedFromWhereItCameBack() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 1
        rig.micSource.push(tone(16_000, 0.2))  // 0-1 s
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.2, count: 16_000))) })
        rig.clock.now = 5  // 4 s pass with nothing from the mic, then it comes back
        rig.micSource.resume()
        #expect(await eventually { rig.sink.calls.contains(.silence(.mic, 4)) })
        rig.clock.now = 5.1
        rig.micSource.push(tone(1_600, 0.4))  // heard 5.0-5.1 s
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.4, count: 1_600))) })
        _ = await rig.session.stop()
        let mix = rig.mixWrites
        try #require(mix.count == 81_600)
        #expect(mix[..<16_000].allSatisfy { abs($0 - 0.2) < 1e-5 })
        #expect(mix[16_000..<80_000].allSatisfy { $0 == 0 }, "the gap is silence in the mix")
        #expect(mix[80_000...].allSatisfy { abs($0 - 0.4) < 1e-5 }, "the audio after the restart is where it was heard")
    }

    @Test func aRestartGapShorterThanTheToleranceIsStillMixedFromWhereTheSourceCameBack() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.clock.now = 1
        rig.micSource.push(tone(16_000, 0.2))  // 0-1 s
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.2, count: 16_000))) })
        rig.clock.now = 1.12  // a quick restart: 0.12 s with nothing
        await rig.session.fillGap(stream: .mic)
        rig.clock.now = 1.22
        rig.micSource.push(tone(1_600, 0.4))  // heard 1.12-1.22 s
        #expect(await eventually { rig.sink.calls.contains(.write(.mic, Array(repeating: 0.4, count: 1_600))) })
        _ = await rig.session.stop()
        let mix = rig.mixWrites
        try #require(mix.count == 19_520)
        #expect(mix[16_000..<17_920].allSatisfy { $0 == 0 })
        #expect(mix[17_920...].allSatisfy { abs($0 - 0.4) < 1e-5 }, "the audio after the restart is where it was heard")
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
            engine: rig.engine, store: rig.store, sink: rig.sink, clock: { clock.now })
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
            engine: rig.engine, store: rig.store, sink: rig.sink, clock: { [clock = rig.clock] in clock.now })
        try await session.start()
        rig.micSource.push(tone(8_000))
        rig.clock.now = 2
        let stopping = Task { await session.stop() }
        #expect(await eventually { slow.isStopping })
        #expect(rig.clock.now == 3)
        slow.release()
        let finished = await stopping.value
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

    // MARK: Speakers

    @Test func engineLabelsBecomePeopleSegmentsGetThemAndBothArePersisted() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.engine.emit(finalEvent("First voice.", 1..<2, speaker: "1"))
        rig.engine.emit(finalEvent("Second voice.", 3..<4, speaker: "2"))
        rig.engine.emit(finalEvent("First again.", 5..<6, speaker: "1"))

        #expect(await eventually { await rig.stored().map(\.speaker) == ["P1", "P2", "P1"] })
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.speakers.count == 2 })
        let saved = try #require(try await rig.store.meeting(id: rig.meeting.id))
        #expect(saved.speakers["P1"]?.name == "Speaker 1" && saved.speakers["P2"]?.name == "Speaker 2")
        #expect(saved.speakers["P1"]?.colorIndex == 0 && saved.speakers["P2"]?.colorIndex == 1)
        let finished = await rig.session.stop()
        #expect(finished.speakers.keys.sorted() == ["P1", "P2"])
    }

    @Test func snapshotsComeAtMostFourTimesASecond() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let received = Mutex<(count: Int, last: MeetingSnapshot?)>((0, nil))
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { received.withLock { $0 = ($0.count + 1, s) } } }
        defer { collector.cancel() }
        try await rig.session.start()
        let began = ContinuousClock.now
        received.withLock { $0.count = 0 }
        for i in 0..<100 {  // the engine says something new every 10 ms
            rig.engine.emit(TranscriptEvent(stream: .mic, text: "word \(i)", isFinal: false))
            rig.clock.now += 0.01
            try await Task.sleep(for: .milliseconds(10))
        }
        let seconds = Double((ContinuousClock.now - began).components.seconds) + 1
        #expect(received.withLock { $0.count } <= Int(4 * seconds) + 2)
        #expect(await eventually { received.withLock { $0.last }?.volatile[.mixed] == "word 99" }, "the newest state still arrives")
        _ = await rig.session.stop()
    }

    // MARK: Renaming while recording

    @Test func aRenameDuringRecordingSurvivesTheNextSpeaker() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        try await rig.session.start()
        rig.engine.emit(finalEvent("First voice.", 1..<2, speaker: "1"))
        rig.engine.emit(finalEvent("Second voice.", 3..<4, speaker: "2"))
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.speakers.count == 2 })

        await rig.session.renameSpeaker("P1", to: "Anna")
        #expect(await eventually { latest.withLock { $0 }?.meeting.speakers["P1"]?.name == "Anna" }, "the live window sees it at once")
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.speakers["P1"]?.name == "Anna" }, "and it is saved")

        rig.engine.emit(finalEvent("A third voice.", 5..<6, speaker: "3"))
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.speakers.count == 3 })
        let saved = try #require(try await rig.store.meeting(id: rig.meeting.id))
        #expect(saved.speakers["P1"]?.name == "Anna", "a new speaker did not bring 'Speaker 1' back")
        #expect(saved.speakers["P3"]?.name == "Speaker 3")
        let finished = await rig.session.stop()
        #expect(finished.speakers["P1"]?.name == "Anna")
        #expect(try await rig.store.meeting(id: rig.meeting.id)?.speakers["P1"]?.name == "Anna")
    }

    @Test func renamingToAnExistingNameDuringRecordingMergesAndTheMergedVoiceStaysMerged() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        try await rig.session.start()
        rig.engine.emit(finalEvent("One.", 1..<2, speaker: "1"))
        rig.engine.emit(finalEvent("Two.", 3..<4, speaker: "2"))
        #expect(await eventually { await rig.stored().map(\.speaker) == ["P1", "P2"] })

        await rig.session.renameSpeaker("P2", to: "speaker 1")  // P1's name, in other case: the same person
        #expect(await eventually { await rig.stored().map(\.speaker) == ["P1", "P1"] }, "the segments follow the merge")

        // The engine still says "2": it must stay with P1, not become a new person.
        rig.engine.emit(finalEvent("Three.", 5..<6, speaker: "2"))
        #expect(await eventually { await rig.stored().count == 3 })
        #expect(await eventually { await rig.stored().last?.speaker == "P1" })
        let finished = await rig.session.stop()
        #expect(finished.speakers.keys.sorted() == ["P1"])
        #expect(finished.mergedSpeakers == ["P2": "P1"])
        let onDisk = try #require(try await rig.store.meeting(id: rig.meeting.id))
        #expect(onDisk.speakers.keys.sorted() == ["P1"], "the merged-away person was not written back")
        #expect(await rig.stored().allSatisfy { $0.speaker == "P1" })
    }

    // MARK: Gaps

    @Test func aGapTheEngineReportsIsRecordedOnTheMeetingAndSaved() async throws {
        let rig = Rig()
        defer { rig.cleanup() }
        let latest = Mutex<MeetingSnapshot?>(nil)
        let snapshots = rig.session.snapshots
        let collector = Task { for await s in snapshots { latest.withLock { $0 = s } } }
        defer { collector.cancel() }
        try await rig.session.start()
        rig.engine.emit(TranscriptEvent(stream: .mixed, text: "", isFinal: true, range: 30..<62, isGap: true))
        #expect(await eventually { latest.withLock { $0 }?.meeting.gaps == [TranscriptGap(start: 30, end: 62)] })
        #expect(await eventually { (try? await rig.store.meeting(id: rig.meeting.id))?.gaps.count == 1 })
        #expect(await rig.stored().isEmpty, "a gap is no segment")
        let finished = await rig.session.stop()
        #expect(finished.gaps == [TranscriptGap(start: 30, end: 62)])
        #expect(try await rig.store.meeting(id: rig.meeting.id)?.gaps == finished.gaps)
    }

    @Test func withoutSpeakerLabelsSegmentsHaveNoSpeaker() async throws {
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
    private let gate = Mutex((entered: false, released: false, waiter: CheckedContinuation<Void, Never>?.none))
    var isStopping: Bool { gate.withLock { $0.entered } }
    func release() {
        let waiter = gate.withLock { s in
            s.released = true
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    init(clock: TestClock) { self.clock = clock }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { try await inner.start(format: format) }
    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async {
        clock.now += 1
        await withCheckedContinuation { continuation in
            let released = gate.withLock { s in
                s.entered = true
                if s.released { return true }
                s.waiter = continuation
                return false
            }
            if released { continuation.resume() }
        }
        await inner.stop()
    }
}
