import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MarkdownExporterTests {
    let utc = TimeZone(identifier: "UTC")!

    var meeting: Meeting {
        var m = Meeting(
            title: "Weekly sync", date: Date(timeIntervalSince1970: 1_793_025_000),  // 2026-10-26 14:30 UTC
            duration: 185, engineID: "fake", mutedRanges: [MutedRange(stream: .mic, start: 30, end: 70)], state: .finished)
        m.pausedRanges = [PausedRange(start: 120, end: 150)]
        m.speakers = [
            "P1": SpeakerInfo(name: "You", colorIndex: 0),
            "P2": SpeakerInfo(name: "Alice", colorIndex: 1),
        ]
        return m
    }

    var segments: [MeetingSegment] {
        [
            MeetingSegment(stream: .mixed, text: "Back again.", start: 155, end: 157, speaker: "P1"),
            MeetingSegment(stream: .mixed, text: "Hi, thanks for joining.", start: 9, end: 11, speaker: "P2"),
            MeetingSegment(stream: .mixed, text: "Hello everyone.", start: 5, end: 7, speaker: "P1"),
            MeetingSegment(stream: .mixed, text: "Unattributed words.", start: 80, end: 82),
            MeetingSegment(stream: .mic, text: "Hi thanks for joining", start: 10, end: 12, echo: true),
        ]
    }

    func golden(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func exportMatchesTheGoldenFile() throws {
        let md = MarkdownExporter.markdown(
            meeting: meeting, segments: segments,
            summary: "## Summary\n\nWe synced.\n\n## Decisions\n\n- Ship Friday.",
            notes: "- ask about the budget\n- Maria owns the launch", timeZone: utc)
        #expect(md == (try golden("golden")))
    }

    @Test func withoutASummaryOrNotesTheTranscriptFollowsTheHeader() throws {
        let md = MarkdownExporter.markdown(meeting: meeting, segments: segments, summary: nil, timeZone: utc)
        #expect(md == (try golden("golden-no-summary")))
    }

    @Test func emptyNotesLeaveOutTheNotesSection() {
        let md = MarkdownExporter.markdown(meeting: meeting, segments: segments, summary: nil, notes: " \n", timeZone: utc)
        #expect(!md.contains("## Notes"))
    }

    @Test func aRenamedSpeakerShowsItsNewNameEverywhere() {
        var m = meeting
        m.speakers["P2"]?.name = "Alice Smith"
        let md = MarkdownExporter.markdown(meeting: m, segments: segments, summary: nil, timeZone: utc)
        #expect(md.contains("**Alice Smith** [00:09] Hi, thanks for joining."))
    }

    @Test func theSystemStreamsMuteIsNamedToo() {
        var m = meeting
        m.mutedRanges = [MutedRange(stream: .system, start: 5, end: 8)]
        let md = MarkdownExporter.markdown(meeting: m, segments: [], summary: nil, timeZone: utc)
        #expect(md.contains("_System audio muted 00:05–00:08_"))
    }

    @Test func meetingsFromBeforeSpeakersStillShowMeAndThem() {
        let old = Meeting(title: "Old", date: Date(timeIntervalSince1970: 1_793_025_000), duration: 20, engineID: "f")
        let segs = [
            MeetingSegment(stream: .mic, text: "Mine.", start: 1, end: 2),
            MeetingSegment(stream: .system, text: "Theirs.", start: 3, end: 4),
        ]
        let md = MarkdownExporter.markdown(meeting: old, segments: segs, summary: nil, timeZone: utc)
        #expect(md.contains("**Me** [00:01] Mine.") && md.contains("**Them** [00:03] Theirs."))
    }

    @Test func timestampsPastAnHourShowHours() {
        let long = [MeetingSegment(stream: .system, text: "Late.", start: 3725, end: 3727)]
        let m = Meeting(title: "Long", date: Date(timeIntervalSince1970: 1_793_025_000), duration: 3800, engineID: "f")
        let md = MarkdownExporter.markdown(meeting: m, segments: long, summary: nil, timeZone: utc)
        #expect(md.contains("**Them** [1:02:05] Late."))
        #expect(md.contains("- Duration: 1:03:20"))
    }
}
