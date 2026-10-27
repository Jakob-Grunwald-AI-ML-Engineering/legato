import Foundation
import LegatoCore

/// The accuracy pass after a meeting: re-transcribes the recording with a ``BatchTranscriber`` and replaces the
/// live text.
///
/// A meeting records one **mix** track (what the live engine heard), and the pass runs once, on that. A meeting
/// from before the mix existed has a recording per stream (mic and system), and the pass runs on each as it
/// used to. The new text gets its speakers from the best turns on disk (offline if present, else live).
///
/// Audio is read one window at a time (see ``AudioWindowing``), so memory stays bounded for long meetings.
/// The live text is saved once to `segments.live.jsonl`; a re-run ("Improve transcript") replaces the
/// post-pass text again and leaves that file alone. A stream with no audio keeps its segments.
public struct MeetingPostPass: Sendable {
    private let store: MeetingStore
    private let reader: any AudioSampleReader
    private let transcriber: any BatchTranscriber

    public init(store: MeetingStore, reader: any AudioSampleReader, transcriber: any BatchTranscriber) {
        self.store = store
        self.reader = reader
        self.transcriber = transcriber
    }

    /// - Parameter progress: told after each window, how much of the recording is transcribed (0 to 1, over all the
    ///   recordings the pass reads).
    public func run(meetingID: UUID, progress: (@Sendable (Double) async -> Void)? = nil) async throws {
        guard try await store.meeting(id: meetingID) != nil else { return }
        var segments = try await store.segments(for: meetingID)
        _ = try await store.saveLiveSegmentsOnce(segments, for: meetingID)

        // A reader with no mix track says so by throwing or by a zero length.
        let mixDuration = (try? await reader.duration(of: .mixed)) ?? 0
        var ordered: [MeetingSegment]
        if mixDuration > 0 {
            var done = Done(total: mixDuration, report: progress)
            let fresh = try await transcribe(.mixed, duration: mixDuration, done: &done)
            let turns = SpeakerAssigner.bestTurns(
                live: try await store.liveTurns(for: meetingID), offline: try await store.offlineTurns(for: meetingID))
            ordered = MeetingStore.ordered(SpeakerAssigner.assign(fresh, turns: turns))
        } else {
            var durations: [TranscriptEvent.Stream: TimeInterval] = [:]
            for stream in [TranscriptEvent.Stream.mic, .system] { durations[stream] = try await reader.duration(of: stream) }
            var done = Done(total: durations.values.reduce(0, +), report: progress)
            for stream in [TranscriptEvent.Stream.mic, .system] {
                let duration = durations[stream] ?? 0
                guard duration > 0 else { continue }
                let fresh = try await transcribe(stream, duration: duration, done: &done)
                segments.removeAll { $0.stream == stream }
                segments += fresh
                done.base += duration
            }
            ordered = MeetingStore.ordered(EchoDeduper.mark(segments))
        }
        try await store.replaceSegments(ordered, for: meetingID)
        // Only this field: the meeting may have been renamed while the post-pass ran.
        let postPassID = transcriber.id
        try await store.update(id: meetingID) { $0.postPassID = postPassID }
    }

    /// How much audio is transcribed out of all there is, and who to tell. `base` is the length of the recordings
    /// already done; a window ends at a position in the current one.
    private struct Done {
        var total: TimeInterval
        var base: TimeInterval = 0
        var report: (@Sendable (Double) async -> Void)?

        func reach(_ position: TimeInterval) async {
            if total > 0 { await report?(min(1, (base + position) / total)) }
        }
    }

    private func transcribe(
        _ stream: TranscriptEvent.Stream, duration: TimeInterval, done: inout Done
    ) async throws -> [MeetingSegment] {
        var result: [MeetingSegment] = []
        var start: TimeInterval = 0
        while start < duration {
            try Task.checkCancellation()
            let end = try await AudioWindowing.nextCut(from: start, duration: duration, stream: stream, reader: reader)
            let samples = try await reader.samples(of: stream, in: start..<end)
            let events = try await transcriber.transcribe(samples: samples, stream: stream)
            for event in events where event.isFinal {
                let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = event.range ?? 0..<(end - start)
                result.append(MeetingSegment(
                    stream: stream, text: text, start: start + range.lowerBound, end: start + range.upperBound, origin: .postPass))
            }
            await done.reach(end)
            start = end
        }
        return result
    }
}
