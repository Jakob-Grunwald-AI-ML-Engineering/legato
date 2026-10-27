import Foundation
import LegatoCore

/// Renders a meeting as Markdown: title, date, duration, the summary, then the transcript.
///
/// The transcript is one paragraph per segment, `**Me** [mm:ss] text` for the mic and `**Them** [mm:ss] text`
/// for the system stream, in time order, with muted ranges noted where they begin. Echoes are left out.
public enum MarkdownExporter {
    /// - Parameters:
    ///   - summary: Markdown placed verbatim after the header (it carries its own headings); omitted when nil.
    ///   - timeZone: Zone of the date line.
    public static func markdown(
        meeting: Meeting, segments: [MeetingSegment], summary: String?, timeZone: TimeZone = .current
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
        blocks.append("## Transcript")

        enum Item {
            case muted(MutedRange)
            case spoken(MeetingSegment)
            var start: TimeInterval {
                switch self {
                case .muted(let r): r.start
                case .spoken(let s): s.start
                }
            }
        }
        let items = (meeting.mutedRanges.map(Item.muted) + segments.filter { !$0.echo }.map(Item.spoken))
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        for item in items {
            switch item {
            case .muted(let r):
                blocks.append("_\(label(r.stream)) muted \(clock(r.start))–\(clock(r.end))_")
            case .spoken(let s):
                blocks.append("**\(label(s.stream))** [\(clock(s.start))] \(s.text)")
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func label(_ stream: TranscriptEvent.Stream) -> String { stream == .mic ? "Me" : "Them" }

    /// `mm:ss`, or `h:mm:ss` from one hour on.
    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : String(format: "%02d:%02d", m, s)
    }
}
