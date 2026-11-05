import Foundation
import LegatoCore

/// Renders a meeting as Markdown: title, date, duration, client, project and tags when set, the summary, the user's notes, then the transcript.
///
/// The transcript is one paragraph per turn (consecutive segments of one speaker), `**Alice** [mm:ss] text` named by the meeting's speakers, in
/// time order, with muted and paused ranges noted where they begin (`_Microphone muted 00:30–01:10_`,
/// `_Paused 02:00–02:30_`, `_Transcript missing 04:10–04:55_`). A segment with no speaker has no name.
public enum MarkdownExporter {
    /// - Parameters:
    ///   - summary: Markdown placed verbatim after the header (it carries its own headings); omitted when nil.
    ///   - notes: the user's notes, under "## Notes"; omitted when nil or blank.
    ///   - timeZone: Zone of the date line.
    public static func markdown(
        meeting: Meeting, segments: [MeetingSegment], summary: String?, notes: String? = nil, timeZone: TimeZone = .current
    ) -> String {
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.timeZone = timeZone
        dateFormat.dateFormat = "yyyy-MM-dd HH:mm"

        var facts = ["- Date: \(dateFormat.string(from: meeting.date))", "- Duration: \(clock(meeting.duration))"]
        if let client = meeting.client { facts.append("- Client: \(client)") }
        if let project = meeting.project { facts.append("- Project: \(project)") }
        if !meeting.tags.isEmpty { facts.append("- Tags: \(meeting.tags.joined(separator: ", "))") }
        var blocks = ["# \(meeting.title)", facts.joined(separator: "\n")]
        if let summary, !summary.isEmpty { blocks.append(summary) }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("## Notes\n\n" + notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        blocks.append("## Transcript")

        enum Item {
            case muted(MutedRange)
            case paused(PausedRange)
            case gap(TranscriptGap)
            case spoken(MeetingTurn)
            var start: TimeInterval {
                switch self {
                case .muted(let r): r.start
                case .paused(let r): r.start
                case .gap(let r): r.start
                case .spoken(let s): s.start
                }
            }
        }
        // Consecutive segments of one speaker read as one turn; no turn spans a muted, paused or missing stretch.
        let breaks = meeting.mutedRanges.map(\.start) + meeting.pausedRanges.map(\.start) + meeting.gaps.map(\.start)
        let turns = MeetingTurns.merge(segments, breakingAt: breaks)
        let items = (meeting.mutedRanges.map(Item.muted) + meeting.pausedRanges.map(Item.paused)
            + meeting.gaps.map(Item.gap) + turns.map(Item.spoken))
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        for item in items {
            switch item {
            case .muted(let r):
                blocks.append("_\(source(r.stream)) muted \(clock(r.start))–\(clock(r.end))_")
            case .paused(let r):
                blocks.append("_Paused \(clock(r.start))–\(clock(r.end))_")
            case .gap(let r):
                blocks.append("_Transcript missing \(clock(r.start))–\(clock(r.end))_")
            case .spoken(let s):
                let stamp = "[\(clock(s.start))] \(s.text)"
                blocks.append(label(s, speakers: meeting.speakers).map { "**\($0)** \(stamp)" } ?? stamp)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func label(_ segment: MeetingTurn, speakers: [PersonID: SpeakerInfo]) -> String? {
        segment.speaker.flatMap { speakers[$0]?.name }
    }

    private static func source(_ stream: TranscriptEvent.Stream) -> String {
        switch stream {
        case .mic: "Microphone"
        case .system: "System audio"
        case .mixed: "Audio"
        }
    }

    /// `mm:ss`, or `h:mm:ss` from one hour on.
    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : String(format: "%02d:%02d", m, s)
    }
}
