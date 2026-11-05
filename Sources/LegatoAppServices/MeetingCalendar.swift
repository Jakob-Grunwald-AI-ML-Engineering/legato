import Foundation

/// A calendar event as the title lookup needs it: plain values, so the choice below is testable and EventKit stays
/// in the app.
public struct CalendarEventInfo: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The other people's display names; the user is left out.
    public var attendees: [String]

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, attendees: [String] = []) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
    }
}

public enum CalendarEventChoice {
    /// How far ahead of its start an event still counts as the one the meeting is for.
    public static let lookahead: TimeInterval = 5 * 60

    /// The event a meeting started at `now` is for: one that is on now or starts within `lookahead`, not all-day and
    /// titled. Of several, the one with attendees, then the one whose start is closest to `now`.
    public static func pick(from events: [CalendarEventInfo], at now: Date) -> CalendarEventInfo? {
        events
            .filter { event in
                !event.isAllDay && !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && event.start <= now.addingTimeInterval(lookahead) && event.end > now
            }
            .min { a, b in
                if a.attendees.isEmpty != b.attendees.isEmpty { return !a.attendees.isEmpty }
                let (da, db) = (abs(a.start.timeIntervalSince(now)), abs(b.start.timeIntervalSince(now)))
                return da != db ? da < db : a.start < b.start
            }
    }
}
