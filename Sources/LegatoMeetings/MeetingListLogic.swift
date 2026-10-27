import Foundation

/// A day's meetings in the list.
public struct MeetingDayGroup: Sendable, Equatable {
    /// Midnight of the day.
    public var day: Date
    /// Newest first.
    public var meetings: [Meeting]
}

/// What the meetings list shows when it has no cards.
public enum MeetingListEmptyState: Sendable, Equatable { case none, noMeetings, searching, noMatch }

/// Whether the live transcript follows its newest line. It stops when the user scrolls up and starts again when
/// they come back to the bottom; the view tells it where a scroll came to rest.
public struct TranscriptFollow: Sendable, Equatable {
    /// How near the bottom counts as "at the bottom", in points.
    public static let tolerance: Double = 40

    public private(set) var follows = true

    public init() {}

    public mutating func scrollSettled(distanceFromBottom: Double) {
        follows = distanceFromBottom <= Self.tolerance
    }
}

/// What the pill (the small floating recorder) shows, from the recorder's state.
public struct MeetingPillState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, starting, recording, stopping }

    public var phase: Phase
    public var paused: Bool
    public var muted: Bool

    public init(phase: Phase, paused: Bool, muted: Bool) {
        self.phase = phase
        self.paused = paused
        self.muted = muted
    }

    /// One word for the state; pause wins over mute.
    public var label: String {
        switch phase {
        case .idle: "Ready"
        case .starting: "Starting"
        case .stopping: "Saving"
        case .recording: paused ? "Paused" : muted ? "Muted" : "Recording"
        }
    }

    /// Mute, pause and end work only while recording.
    public var controlsEnabled: Bool { phase == .recording }
}

/// The meetings list's pure rules: grouping by day, the card's one line, search, and which summary a
/// meeting's document shows.
public enum MeetingListLogic {
    /// Meetings grouped by calendar day, newest day first and newest meeting first within it.
    public static func groupByDay(_ meetings: [Meeting], calendar: Calendar = .current) -> [MeetingDayGroup] {
        let byDay = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            MeetingDayGroup(day: day, meetings: byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    /// "Today", "Yesterday", else the date written out.
    public static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    /// The card's second line: the first sentence of the summary's "Summary" section; without one, the
    /// first line of the transcript (echoes left out). Empty when there is neither.
    public static func oneLiner(summary: String?, segments: [MeetingSegment]) -> String {
        if let summary, let section = summarySection(of: summary) {
            let cleaned = strip(section)
            if let first = firstSentence(of: cleaned), !first.isEmpty { return first }
        }
        return segments.first { !$0.echo && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// Whether a meeting matches a search: every word of `query` appears (ignoring case and accents) in the
    /// title, a summary, the notes, a speaker's name or the transcript. A blank query matches everything.
    public static func matches(
        _ query: String, meeting: Meeting, summaries: [String], notes: String?, segments: [MeetingSegment]
    ) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        var parts = [meeting.title] + summaries + meeting.speakers.values.map(\.name) + segments.map(\.text)
        if let notes { parts.append(notes) }
        let haystack = parts.joined(separator: "\n")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The card's line for a meeting: the first sentence of the summary of the meeting's own template (not another
    /// template's, newer or not), else the first line of the transcript. Empty when there is neither.
    public static func cardLine(meeting: Meeting, summaries: [MeetingStore.Summary], segments: [MeetingSegment]) -> String {
        let shown = shownSummary(in: summaries, templateID: meeting.templateID)
        return oneLiner(summary: shown?.text, segments: segments)
    }

    /// What decides whether a card's line has to be read again: the meeting's state, steps, length, title and
    /// template, and which summary is shown (its template, backend and when it was written).
    public static func cardSignature(meeting: Meeting, summaries: [MeetingStore.Summary]) -> String {
        let shown = shownSummary(in: summaries, templateID: meeting.templateID)
        let summary = shown.map { "\($0.templateID)/\($0.backendID)/\($0.date.timeIntervalSince1970)/\($0.text.count)" } ?? "none"
        return "\(meeting.state.rawValue)/\(meeting.completedSteps.count)/\(Int(meeting.duration))/\(meeting.title)/\(meeting.templateID)/\(summary)"
    }

    /// What the list shows when it has no cards: nothing, "no meetings", "searching…" or "no match". A search that
    /// has not finished scanning says so rather than claiming that nothing matches.
    public static func emptyState(shownCount: Int, hasLive: Bool, query: String, searchReady: Bool) -> MeetingListEmptyState {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if shownCount > 0 { return .none }
        if searching { return searchReady ? .noMatch : .searching }
        return hasLive ? .none : .noMeetings
    }

    /// "1:05", or "1:02:05" from an hour on.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The newest summary of the template the meeting is set to; nil when there is none (the document offers Generate).
    public static func shownSummary(in summaries: [MeetingStore.Summary], templateID: String) -> MeetingStore.Summary? {
        summaries.filter { $0.templateID == templateID }.max { $0.date < $1.date }
    }

    // MARK: Text

    private static func summarySection(of markdown: String) -> String? {
        var inSection = false
        var lines: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                if inSection { break }
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                inSection = title.caseInsensitiveCompare("Summary") == .orderedSame
            } else if inSection {
                lines.append(String(line))
            }
        }
        return inSection || !lines.isEmpty ? lines.joined(separator: "\n") : nil
    }

    private static func strip(_ text: String) -> String {
        text.split(separator: "\n").map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["- [ ] ", "- ", "* ", "• "] where s.hasPrefix(bullet) { s = String(s.dropFirst(bullet.count)); break }
            return s
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")
    }

    private static func firstSentence(of text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var end = t.endIndex
        var i = t.startIndex
        while i < t.endIndex {
            if ".!?".contains(t[i]) {
                let next = t.index(after: i)
                if next == t.endIndex || t[next].isWhitespace {
                    end = next
                    break
                }
            }
            i = t.index(after: i)
        }
        return String(t[..<end]).trimmingCharacters(in: .whitespaces)
    }
}
