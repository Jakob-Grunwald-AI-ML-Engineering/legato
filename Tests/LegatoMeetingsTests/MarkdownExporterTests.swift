import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MarkdownExporterTests {
    let utc = TimeZone(identifier: "UTC")!

    var meeting: Meeting {
        Meeting(
            title: "Weekly sync", date: Date(timeIntervalSince1970: 1_793_025_000),  // 2026-10-26 14:30 UTC
            duration: 125, engineID: "fake", mutedRanges: [MutedRange(stream: .mic, start: 30, end: 70)], state: .finished)
    }

    var segments: [MeetingSegment] {
        [
            MeetingSegment(stream: .mic, text: "Back again.", start: 75, end: 77),
            MeetingSegment(stream: .system, text: "Hi, thanks for joining.", start: 9, end: 11),
            MeetingSegment(stream: .mic, text: "Hello everyone.", start: 5, end: 7),
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
            summary: "## Summary\n\nWe synced.\n\n## Decisions\n\n- Ship Friday.", timeZone: utc)
        #expect(md == (try golden("golden")))
    }

    @Test func withoutASummaryTheTranscriptFollowsTheHeader() throws {
        let md = MarkdownExporter.markdown(meeting: meeting, segments: segments, summary: nil, timeZone: utc)
        #expect(md == (try golden("golden-no-summary")))
    }

    @Test func timestampsPastAnHourShowHours() {
        let long = [MeetingSegment(stream: .system, text: "Late.", start: 3725, end: 3727)]
        let m = Meeting(title: "Long", date: Date(timeIntervalSince1970: 1_793_025_000), duration: 3800, engineID: "f")
        let md = MarkdownExporter.markdown(meeting: m, segments: long, summary: nil, timeZone: utc)
        #expect(md.contains("**Them** [1:02:05] Late."))
        #expect(md.contains("- Duration: 1:03:20"))
    }
}
