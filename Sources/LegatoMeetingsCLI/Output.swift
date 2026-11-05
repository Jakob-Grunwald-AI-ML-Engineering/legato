import Foundation
import LegatoMeetings

/// What the commands print: stable JSON, or Markdown/plain text for reading.
enum Output {
    // MARK: JSON

    static func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }

    /// A meeting as one row of a list: its metadata only.
    static func row(_ meeting: Meeting) -> JSONValue {
        [
            "id": .string(meeting.id.uuidString),
            "title": .string(meeting.title),
            "date": .string(iso(meeting.date)),
            "duration_seconds": .number(meeting.duration.rounded()),
            "client": JSONValue(meeting.client),
            "project": JSONValue(meeting.project),
            "tags": .array(meeting.tags.map(JSONValue.string)),
            "state": .string(meeting.state.rawValue),
        ]
    }

    static func list(_ meetings: [Meeting]) -> JSONValue {
        ["meetings": .array(meetings.map(row))]
    }

    static func search(_ hits: [SearchHit]) -> JSONValue {
        let rows = hits.map { hit -> JSONValue in
            guard case .object(var object) = row(hit.meeting) else { return .null }
            object["snippets"] = .array(hit.snippets.map { snippet in
                [
                    "source": .string(snippet.source),
                    "text": .string(snippet.text),
                    "at_seconds": snippet.atSeconds.map { .number($0.rounded()) } ?? .null,
                ]
            })
            return .object(object)
        }
        return ["meetings": .array(rows)]
    }

    static func detail(_ detail: MeetingDetail) -> JSONValue {
        guard case .object(var object) = row(detail.meeting) else { return .null }
        let meeting = detail.meeting
        func name(_ id: PersonID?) -> JSONValue { JSONValue(id.flatMap { meeting.speakers[$0]?.name }) }
        object["locale"] = JSONValue(meeting.locale)
        object["folder"] = .string(detail.folder.path)
        object["summary_failure"] = JSONValue(meeting.summaryFailure)
        object["speakers"] = .array(meeting.speakers.sorted { $0.key < $1.key }.map { ["id": .string($0.key), "name": .string($0.value.name)] })
        object["summary"] = detail.summary.map { summary -> JSONValue in
            [
                "backend": .string(summary.backendID),
                "written": .string(iso(summary.date)),
                "stale": .bool(summary.isStale),
                "text": .string(summary.text),
            ]
        } ?? .null
        object["notes"] = JSONValue(detail.notes)
        object["transcript"] = .array(detail.segments.map { segment in
            [
                "start_seconds": .number(segment.start),
                "end_seconds": .number(segment.end),
                "speaker_id": JSONValue(segment.speaker),
                "speaker": name(segment.speaker),
                "text": .string(segment.text),
            ]
        })
        return .object(object)
    }

    // MARK: Text

    private static func localTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// `3F2A91C4  2026-11-04 14:30  45:10  Weekly sync  [Acme / Website]  #planning`
    private static func line(_ meeting: Meeting) -> String {
        var parts = [String(meeting.id.uuidString.prefix(8)), localTime(meeting.date), MeetingListLogic.clock(meeting.duration), meeting.title]
        let filing = [meeting.client, meeting.project].compactMap { $0 }.joined(separator: " / ")
        if !filing.isEmpty { parts.append("[\(filing)]") }
        if !meeting.tags.isEmpty { parts.append(meeting.tags.map { "#\($0)" }.joined(separator: " ")) }
        if meeting.state != .finished { parts.append("(\(meeting.state.rawValue))") }
        return parts.joined(separator: "  ")
    }

    static func listText(_ meetings: [Meeting]) -> String {
        meetings.isEmpty ? "No meetings found.\n" : meetings.map(line).joined(separator: "\n") + "\n"
    }

    static func searchText(_ hits: [SearchHit]) -> String {
        guard !hits.isEmpty else { return "No meetings found.\n" }
        return hits.map { hit in
            ([line(hit.meeting)] + hit.snippets.map { snippet in
                let at = snippet.atSeconds.map { " \(MeetingListLogic.clock($0))" } ?? ""
                return "    \(snippet.source)\(at): \(snippet.text)"
            }).joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    /// The exporter's Markdown, with the meeting's id and state added under its Date and Duration lines (it does not carry them).
    static func detailText(_ detail: MeetingDetail) -> String {
        let meeting = detail.meeting
        let markdown = MarkdownExporter.markdown(meeting: meeting, segments: detail.segments, summary: detail.summary?.text, notes: detail.notes)
        var extra = ["- ID: \(meeting.id.uuidString)"]
        if meeting.state != .finished { extra.append("- State: \(meeting.state.rawValue)") }
        var lines = markdown.components(separatedBy: "\n")
        let at = lines.firstIndex { $0.hasPrefix("- Duration:") }.map { $0 + 1 } ?? min(1, lines.count)
        lines.insert(contentsOf: extra, at: at)
        return lines.joined(separator: "\n")
    }
}
