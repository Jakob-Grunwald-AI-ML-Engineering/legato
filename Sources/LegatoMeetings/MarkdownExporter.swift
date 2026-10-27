import Foundation
import LegatoCore

/// Renders a meeting as Markdown: title, date, duration, the summary, the user's notes, then the transcript.
///
/// The transcript is one paragraph per segment, `**Alice** [mm:ss] text` named by the meeting's speakers, in
/// time order, with muted and paused ranges noted where they begin (`_Microphone muted 00:30–01:10_`,
/// `_Paused 02:00–02:30_`). A segment with no speaker has no name, those of older two-stream meetings included.
/// Echoes are left out.
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

        var blocks = [
            "# \(meeting.title)",
            "- Date: \(dateFormat.string(from: meeting.date))\n- Duration: \(clock(meeting.duration))",
        ]
        if let summary, !summary.isEmpty { blocks.append(summary) }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append("## Notes\n\n" + notes.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        blocks.append("## Transcript")

        enum Item {
            case muted(MutedRange)
            case paused(PausedRange)
            case spoken(MeetingSegment)
            var start: TimeInterval {
                switch self {
                case .muted(let r): r.start
                case .paused(let r): r.start
                case .spoken(let s): s.start
                }
            }
        }
        let items = (meeting.mutedRanges.map(Item.muted) + meeting.pausedRanges.map(Item.paused)
            + segments.filter { !$0.echo }.map(Item.spoken))
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        for item in items {
            switch item {
            case .muted(let r):
                blocks.append("_\(source(r.stream)) muted \(clock(r.start))–\(clock(r.end))_")
            case .paused(let r):
                blocks.append("_Paused \(clock(r.start))–\(clock(r.end))_")
            case .spoken(let s):
                let stamp = "[\(clock(s.start))] \(s.text)"
                blocks.append(label(s, speakers: meeting.speakers).map { "**\($0)** \(stamp)" } ?? stamp)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func label(_ segment: MeetingSegment, speakers: [PersonID: SpeakerInfo]) -> String? {
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
