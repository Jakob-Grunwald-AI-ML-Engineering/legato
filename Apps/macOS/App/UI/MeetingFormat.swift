import Foundation

/// How the Meetings window writes lengths and times.
enum MeetingFormat {
    /// "42 min", "1 h 05 min"; empty for a meeting without length.
    static func length(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? String(format: "%d h %02d min", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    /// The time of day, the one way every row and header writes it.
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

    /// "Wed 09:10".
    static func when(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated)) + " " + time(date) }

    /// "Acme › Website relaunch", "Acme" or nil.
    static func folder(client: String?, project: String?) -> String? {
        let parts = [client, project].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }
}
