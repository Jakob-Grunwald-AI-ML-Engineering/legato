import Foundation
import LegatoCore

/// The accuracy pass after a meeting: re-transcribes each recorded stream with a ``BatchTranscriber``
/// and replaces that stream's live text.
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
        guard var meeting = try await store.meeting(id: meetingID) else { return }
        var segments = try await store.segments(for: meetingID)
        _ = try await store.saveLiveSegmentsOnce(segments, for: meetingID)

        for stream in [TranscriptEvent.Stream.mic, .system] {
            let duration = try await reader.duration(of: stream)
            guard duration > 0 else { continue }
            let fresh = try await transcribe(stream, duration: duration)
            segments.removeAll { $0.stream == stream }
            segments += fresh
        }

        let ordered = MeetingStore.ordered(EchoDeduper.mark(segments))
        try await store.replaceSegments(ordered, for: meetingID)
        meeting.postPassID = transcriber.id
        try await store.update(meeting)
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
