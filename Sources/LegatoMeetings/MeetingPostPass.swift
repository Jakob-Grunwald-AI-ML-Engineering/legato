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

    public func run(meetingID: UUID) async throws {
        guard try await store.meeting(id: meetingID) != nil else { return }
        var segments = try await store.segments(for: meetingID)
        _ = try await store.saveLiveSegmentsOnce(segments, for: meetingID)

        // A reader with no mix track says so by throwing or by a zero length.
        let mixDuration = (try? await reader.duration(of: .mixed)) ?? 0
        var ordered: [MeetingSegment]
        if mixDuration > 0 {
            let fresh = try await transcribe(.mixed, duration: mixDuration)
            let turns = SpeakerAssigner.bestTurns(
                live: try await store.liveTurns(for: meetingID), offline: try await store.offlineTurns(for: meetingID))
            ordered = MeetingStore.ordered(SpeakerAssigner.assign(fresh, turns: turns))
        } else {
            for stream in [TranscriptEvent.Stream.mic, .system] {
                let duration = try await reader.duration(of: stream)
                guard duration > 0 else { continue }
                let fresh = try await transcribe(stream, duration: duration)
                segments.removeAll { $0.stream == stream }
                segments += fresh
            }
            ordered = MeetingStore.ordered(EchoDeduper.mark(segments))
        }
        try await store.replaceSegments(ordered, for: meetingID)
        // Only this field: the meeting may have been renamed while the post-pass ran.
        let postPassID = transcriber.id
        try await store.update(id: meetingID) { $0.postPassID = postPassID }
    }

    private func transcribe(_ stream: TranscriptEvent.Stream, duration: TimeInterval) async throws -> [MeetingSegment] {
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
            start = end
        }
        return result
    }
}
