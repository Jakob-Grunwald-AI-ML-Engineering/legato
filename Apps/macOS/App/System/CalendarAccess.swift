import AppKit
import EventKit
import LegatoAppServices

/// The user's calendar for meeting titles: whether Legato may read it, asking for that, and the events around now.
/// Meetings only ever read events (full access, never written), and only when the user turned the setting on.
enum CalendarAccess {
    enum Status: Equatable { case notDetermined, granted, denied }

    static var status: Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        // Write-only access cannot read the events, so it counts as off.
        default: .denied
        }
    }

    /// Asks for full access (the system dialog). A menu-bar app has to come forward first or the dialog stays hidden.
    @MainActor static func request() async {
        WindowPresenter.forceActivate()
        _ = try? await EKEventStore().requestFullAccessToEvents()
    }

    @MainActor static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }

    /// The events on, or starting soon after, `now`, as plain values; empty without access. Reads the store
    /// synchronously, so callers keep it off the main thread. Cancelled events and ones the user declined are left out.
    static func events(around now: Date) -> [CalendarEventInfo] {
        guard status == .granted else { return [] }
        let store = EKEventStore()
        let window = store.predicateForEvents(
            withStart: now.addingTimeInterval(-24 * 3600), end: now.addingTimeInterval(CalendarEventChoice.lookahead + 1), calendars: nil)
        return store.events(matching: window).compactMap { event in
            let title = event.title ?? ""
            guard event.status != .canceled, event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
                  let start = event.startDate, let end = event.endDate else { return nil }
            return CalendarEventInfo(title: title, start: start, end: end, isAllDay: event.isAllDay, attendees: names(of: event))
        }
    }

    /// The others on the invitation, organizer first, in the order of the invitation; no rooms or the user.
    private static func names(of event: EKEvent) -> [String] {
        var seen = Set<String>()
        return ([event.organizer].compactMap { $0 } + (event.attendees ?? []))
            .filter { !$0.isCurrentUser && ($0.participantType == .person || $0.participantType == .unknown) }
            .compactMap(name)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func name(of participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let address = participant.url.absoluteString
        return address.hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : nil
    }
}
