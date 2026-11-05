import AppKit
import LegatoAppServices
import SwiftUI

/// Settings, Meetings: titling a new meeting after the calendar event happening now. Opt-in; Legato only reads.
struct SettingsCalendarCard: View {
    private let settings = MeetingSettings(defaults: .standard)
    @State private var enabled = false
    @State private var access = CalendarAccess.status

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Calendar", systemImage: "calendar").font(.headline)
                Toggle("Title meetings after the calendar event", isOn: $enabled)
                    .onChange(of: enabled) { _, value in settings.calendarTitles = value }
                Text("A meeting takes the title of the event on now or starting within 5 minutes, and offers its attendees as speaker names. "
                    + "Your own title is never replaced.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status
            }
        }
        .task { enabled = settings.calendarTitles; access = CalendarAccess.status }
        // Back from System Settings after changing the access.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in access = CalendarAccess.status }
    }

    private var status: some View {
        HStack(spacing: 10) {
            Image(systemName: access == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(access == .granted ? Color.green : Color.secondary)
            Text(statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch access {
            case .granted: EmptyView()
            case .notDetermined:
                Button("Allow Calendar Access…") {
                    Task {
                        await CalendarAccess.request()
                        access = CalendarAccess.status
                    }
                }
                .controlSize(.small).accessibilityIdentifier("settings.calendar.allow")
            case .denied:
                Button("Open System Settings") { CalendarAccess.openSettings() }.controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch access {
        case .granted: "Legato can read your calendar."
        case .notDetermined: "Legato has not asked for calendar access yet."
        case .denied: "Calendar access is off. Allow Legato full access under System Settings, Privacy & Security, Calendars."
        }
    }
}
