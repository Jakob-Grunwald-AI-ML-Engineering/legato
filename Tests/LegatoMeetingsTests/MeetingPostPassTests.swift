import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoMeetings

/// The post-pass window the tests use, a quarter of the app's 10 minutes: the recordings below are a quarter as
/// long as the 25 minutes the app sees, so the tests scan a quarter of the audio and keep the same shape (three
/// windows, cut at the two quiet points).
private let testWindow: TimeInterval = AudioWindowing.maxWindow / 4

private func scaledPass(store: MeetingStore, reader: any AudioSampleReader, transcriber: any BatchTranscriber) -> MeetingPostPass {
    MeetingPostPass(store: store, reader: reader, transcriber: transcriber, window: testWindow)
}

/// A 6¼-minute recording (a quarter of 25 minutes) synthesised on demand: a constant tone with 2 s gaps at
/// 135-137 s and 270-272 s (the quiet points, 15 s before the end of the first and the second window), and a
/// muted (all-zero) range at 175-190 s. By default it has the two per-stream recordings of an old meeting; with
/// `hasMix` it has the one mix track of a new one and nothing else.
private final class FakeRecording: AudioSampleReader {
    static let rate = 16_000
    /// The whole recording, in seconds.
    static let fullLength: TimeInterval = 375
    let length: TimeInterval
    let gaps: [Range<TimeInterval>] = [135..<137, 270..<272, 175..<190]
    let hasMix: Bool
    let requests = Mutex<[Range<TimeInterval>]>([])
    let streamsRead = Mutex<Set<TranscriptEvent.Stream>>([])

    init(hasMix: Bool = false, length: TimeInterval = FakeRecording.fullLength) {
        self.hasMix = hasMix
        self.length = length
    }

    func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval {
        (stream == .mixed) == hasMix ? length : 0
    }

    func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float] {
        requests.withLock { $0.append(range) }
        streamsRead.withLock { _ = $0.insert(stream) }
        let lo = max(0, Int(range.lowerBound * Double(Self.rate))), hi = min(Int(length * Double(Self.rate)), Int(range.upperBound * Double(Self.rate)))
        guard lo < hi else { return [] }
        var out = [Float](repeating: 0.5, count: hi - lo)
        for gap in gaps {
            let a = max(lo, Int(gap.lowerBound * Double(Self.rate))), b = min(hi, Int(gap.upperBound * Double(Self.rate)))
            if a < b { for i in a..<b { out[i - lo] = 0 } }
        }
        return out
    }
}

/// Reports one segment per run of sound (zero gaps of 0.5 s or more split runs), at its true position
/// within the window it is given, so tests can check the offsets against the recording.
private final class BurstTranscriber: BatchTranscriber {
    let id = "fake-batch"
    let windowLengths = Mutex<[Int]>([])
    let text: @Sendable (TranscriptEvent.Stream) -> String

    init(text: @escaping @Sendable (TranscriptEvent.Stream) -> String = { $0 == .mic ? "alpha beta" : "gamma delta" }) { self.text = text }

    func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
        windowLengths.withLock { $0.append(samples.count) }
        let minGap = 8_000
        var events: [TranscriptEvent] = []
        var runStart: Int?, lastSound = 0
        samples.withUnsafeBufferPointer { buf in
            for i in 0..<buf.count where buf[i] != 0 {
                if let start = runStart, i - lastSound >= minGap { events.append(event(start, lastSound + 1, stream)); runStart = nil }
                if runStart == nil { runStart = i }
                lastSound = i
            }
        }
        if let start = runStart { events.append(event(start, lastSound + 1, stream)) }
        return events
    }

    private func event(_ a: Int, _ b: Int, _ stream: TranscriptEvent.Stream) -> TranscriptEvent {
        finalEvent(text(stream), (Double(a) / 16_000)..<(Double(b) / 16_000), stream: stream)
    }
}

/// Serialized: each test scans 6¼ minutes of audio on two streams, and run in parallel they would hold threads
/// of the cooperative pool, starving timer-based tests elsewhere on a small CI runner.
@Suite(.serialized) struct MeetingPostPassTests {
    func setUp(live: [MeetingSegment] = []) async throws -> (MeetingStore, Meeting, URL) {
        let root = tempRoot()
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 0), duration: FakeRecording.fullLength, engineID: "live-fake", state: .processing)
        try await store.create(meeting)
        for s in live { try await store.appendSegment(s, to: meeting.id) }
        return (store, meeting, root)
    }

    func live(_ text: String, _ stream: TranscriptEvent.Stream, _ start: TimeInterval) -> MeetingSegment {
        MeetingSegment(stream: stream, text: text, start: start, end: start + 1)
    }

    @Test func splitsALongRecordingAtQuietPoints() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = BurstTranscriber()
        try await scaledPass(store: store, reader: FakeRecording(), transcriber: transcriber).run(meetingID: meeting.id)

        // Each stream: windows of at most the window length, 3 of them, cut inside the 2 s gaps.
        let lengths = transcriber.windowLengths.withLock { $0 }
        #expect(lengths.count == 6)
        #expect(lengths.allSatisfy { $0 <= Int(testWindow) * 16_000 })
        // Windows run in order, so mic's three windows come first; their cumulative ends are the cuts.
        let cuts = lengths.prefix(3).reduce(into: [Double]()) { $0.append(($0.last ?? 0) + Double($1) / 16_000) }
        #expect((135.0...137.0).contains(cuts[0]))
        #expect((270.0...272.0).contains(cuts[1]))
        #expect(cuts[2] == 375)
    }

    @Test func theMixPassReportsTheShareOfTheRecordingTranscribedAfterEachWindow() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Mutex<[Double]>([])
        try await scaledPass(store: store, reader: FakeRecording(hasMix: true), transcriber: BurstTranscriber())
            .run(meetingID: meeting.id, progress: { f in seen.withLock { $0.append(f) } })
        let values = seen.withLock { $0 }
        #expect(values.count == 3, "three windows of the mix")
        #expect(values == values.sorted() && values.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect((135.0 / 375 - 0.01...137.0 / 375 + 0.01).contains(values[0]))
        #expect(values.last == 1)
    }

    @Test func anOldMeetingWithTwoRecordingsReportsOneRunningShareAcrossBoth() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Mutex<[Double]>([])
        try await scaledPass(store: store, reader: FakeRecording(), transcriber: BurstTranscriber())
            .run(meetingID: meeting.id, progress: { f in seen.withLock { $0.append(f) } })
        let values = seen.withLock { $0 }
        #expect(values.count == 6)
        #expect(values == values.sorted() && values.last == 1)
        #expect(values[2] < 0.51 && values[2] > 0.49, "the mic recording is half the work")
    }

    @Test func offsetsRangesIncludingAfterAMutedRange() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        try await scaledPass(store: store, reader: FakeRecording(), transcriber: BurstTranscriber()).run(meetingID: meeting.id)

        // The runs of sound in the recording: before the first gap, between gap and mute, after the mute...
        let truth: [(TimeInterval, TimeInterval)] = [(0, 135), (137, 175), (190, 270), (272, 375)]
        for stream in [TranscriptEvent.Stream.mic, .system] {
            let got = try await store.segments(for: meeting.id).filter { $0.stream == stream }
            #expect(got.count == truth.count)
            for (segment, expected) in zip(got, truth) {
                #expect(abs(segment.start - expected.0) < 0.01)
                #expect(abs(segment.end - expected.1) < 0.01)
                #expect(segment.origin == .postPass)
            }
        }
    }

    @Test func replacesSegmentsAndSavesLiveTextOnce() async throws {
        let liveSegs = [live("hello", .mic, 1), live("hi there", .system, 2)]
        let (store, meeting, root) = try await setUp(live: liveSegs)
        defer { try? FileManager.default.removeItem(at: root) }
        let pass = scaledPass(store: store, reader: FakeRecording(), transcriber: BurstTranscriber())
        try await pass.run(meetingID: meeting.id)

        let after = try await store.segments(for: meeting.id)
        #expect(after.allSatisfy { $0.origin == .postPass })
        #expect(!after.contains { $0.text == "hello" })
        #expect(try await store.meeting(id: meeting.id)?.postPassID == "fake-batch")
        let saved = try await store.liveSegments(for: meeting.id)
        #expect(saved == liveSegs)

        // A second run must not overwrite the live text with post-pass text.
        try await pass.run(meetingID: meeting.id)
        #expect(try await store.liveSegments(for: meeting.id) == liveSegs)
    }

    @Test func rerunIsIdempotent() async throws {
        let (store, meeting, root) = try await setUp(live: [live("hello", .mic, 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        let pass = scaledPass(store: store, reader: FakeRecording(), transcriber: BurstTranscriber())
        func shape(_ segs: [MeetingSegment]) -> [String] { segs.map { "\($0.stream.rawValue)|\($0.text)|\($0.start)|\($0.end)|\($0.origin.rawValue)|\($0.echo)" } }
        try await pass.run(meetingID: meeting.id)
        let first = shape(try await store.segments(for: meeting.id))
        try await pass.run(meetingID: meeting.id)
        let second = shape(try await store.segments(for: meeting.id))
        #expect(second == first)
        #expect(first.count == 8)
    }

    @Test func rerunsEchoMarkingOverTheMergedSet() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let same = BurstTranscriber(text: { _ in "we ship on friday" })
        try await scaledPass(store: store, reader: FakeRecording(), transcriber: same).run(meetingID: meeting.id)
        let after = try await store.segments(for: meeting.id)
        #expect(after.filter { $0.stream == .mic }.allSatisfy { $0.echo })
        #expect(after.filter { $0.stream == .system }.allSatisfy { !$0.echo })
    }

    @Test func readsOneWindowAtATime() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = FakeRecording()
        try await scaledPass(store: store, reader: reader, transcriber: BurstTranscriber()).run(meetingID: meeting.id)
        #expect(reader.requests.withLock { $0 }.allSatisfy { $0.upperBound - $0.lowerBound <= testWindow + 0.001 })
    }

    @Test func aStreamWithoutAudioKeepsItsSegments() async throws {
        final class MicOnly: AudioSampleReader {
            let inner = FakeRecording()
            func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval { stream == .mic ? FakeRecording.fullLength : 0 }
            func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float] {
                try await inner.samples(of: stream, in: range)
            }
        }
        let (store, meeting, root) = try await setUp(live: [live("kept", .system, 3)])
        defer { try? FileManager.default.removeItem(at: root) }
        try await scaledPass(store: store, reader: MicOnly(), transcriber: BurstTranscriber()).run(meetingID: meeting.id)
        let after = try await store.segments(for: meeting.id)
        #expect(after.contains { $0.text == "kept" && $0.origin == .live })
        #expect(after.filter { $0.stream == .mic }.count == 4)
    }

    @Test func aRenameDuringThePostPassSurvives() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        struct Renaming: BatchTranscriber {
            let id = "renaming"
            let store: MeetingStore
            let meetingID: UUID
            func transcribe(samples: [Float], stream: TranscriptEvent.Stream) async throws -> [TranscriptEvent] {
                try await store.update(id: meetingID) { $0.title = "Renamed while processing" }
                return []
            }
        }
        try await scaledPass(store: store, reader: FakeRecording(), transcriber: Renaming(store: store, meetingID: meeting.id))
            .run(meetingID: meeting.id)
        let saved = try #require(try await store.meeting(id: meeting.id))
        #expect(saved.title == "Renamed while processing")
        #expect(saved.postPassID == "renaming")
    }
}

/// Shorter recordings (just under three minutes, enough for two windows) keep these cheaper still.
@Suite(.serialized) struct MeetingPostPassOnTheMixTests {
    func setUp() async throws -> (MeetingStore, Meeting, URL) {
        let root = tempRoot()
        let store = MeetingStore(root: root)
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 0), duration: 175, engineID: "live-fake", state: .processing)
        try await store.create(meeting)
        return (store, meeting, root)
    }

    @Test func runsOnceOnTheMixInsteadOfOncePerStream() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = FakeRecording(hasMix: true, length: 175)
        let transcriber = BurstTranscriber(text: { _ in "mixed words" })
        try await scaledPass(store: store, reader: reader, transcriber: transcriber).run(meetingID: meeting.id)

        #expect(transcriber.windowLengths.withLock { $0 }.count == 2, "two windows of the one track, not four")
        #expect(reader.streamsRead.withLock { $0 } == [.mixed])
        let after = try await store.segments(for: meeting.id)
        #expect(after.count == 2)
        #expect(after.allSatisfy { $0.stream == .mixed && $0.origin == .postPass && !$0.echo })
    }

    @Test func aReaderThatThrowsForTheMixFallsBackToTheStreams() async throws {
        struct NoMixReader: AudioSampleReader {
            let inner = FakeRecording(length: 175)
            func duration(of stream: TranscriptEvent.Stream) async throws -> TimeInterval {
                if stream == .mixed { throw MixMissing() }
                return try await inner.duration(of: stream)
            }
            func samples(of stream: TranscriptEvent.Stream, in range: Range<TimeInterval>) async throws -> [Float] {
                try await inner.samples(of: stream, in: range)
            }
        }
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        try await scaledPass(store: store, reader: NoMixReader(), transcriber: BurstTranscriber()).run(meetingID: meeting.id)
        let after = try await store.segments(for: meeting.id)
        #expect(after.count == 4)
        #expect(Set(after.map(\.stream)) == [.mic, .system])
    }

    @Test func newTextGetsItsSpeakersFromTheBestTurns() async throws {
        let (store, meeting, root) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        // Runs of sound: 0-135 and 137-175.
        try await store.saveLiveTurns([SpeakerTurn(speaker: "P1", start: 0, end: 140), SpeakerTurn(speaker: "P2", start: 140, end: 175)], for: meeting.id)
        let pass = scaledPass(store: store, reader: FakeRecording(hasMix: true, length: 175), transcriber: BurstTranscriber(text: { _ in "words" }))
        try await pass.run(meetingID: meeting.id)
        var after = try await store.segments(for: meeting.id)
        #expect(after.map(\.speaker) == ["P1", "P2"])

        // Offline turns, once they exist, win over the live ones.
        try await store.saveOfflineTurns([SpeakerTurn(speaker: "P3", start: 0, end: 175)], for: meeting.id)
        try await pass.run(meetingID: meeting.id)
        after = try await store.segments(for: meeting.id)
        #expect(after.allSatisfy { $0.speaker == "P3" })
    }
}

private struct MixMissing: Error {}

@Suite struct AudioWindowingTests {
    @Test func quietestPointPicksLowestEnergyFrame() {
        var samples = [Float](repeating: 0.5, count: 16_000 * 10)
        for i in 32_000..<33_600 { samples[i] = 0.01 } // 2.0-2.1 s
        let cut = AudioWindowing.quietestPoint(in: samples, offset: 100)
        #expect(cut >= 102 && cut <= 102.1)
    }
}
