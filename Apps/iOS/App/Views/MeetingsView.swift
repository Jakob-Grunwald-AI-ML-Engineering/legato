import LegatoMeetings
import SwiftUI

/// The library of recorded meetings, and the way to start one. A meeting that records is the first row.
struct MeetingsView: View {
    let controller: AppController
    @State private var showsLive = false

    private var meetings: MeetingController { controller.meetings }

    var body: some View {
        List {
            if meetings.isActive {
                Section {
                    NavigationLink {
                        MeetingLiveView(controller: controller)
                    } label: {
                        Label(meetings.statusText, systemImage: "record.circle")
                            .foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("meetings.live")
                }
            }
            if let notice = meetings.notice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("meetings.notice")
                }
            }
            Section {
                ForEach(meetings.meetings.filter { $0.state != .recording || !meetings.isActive }) { meeting in
                    NavigationLink {
                        MeetingDetailView(controller: controller, meeting: meeting)
                    } label: {
                        MeetingRow(meeting: meeting, busy: meetings.busy.contains(meeting.id))
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { meetings.meetings[$0] }
                    Task { for meeting in doomed { await meetings.delete(meeting) } }
                }
            }
        }
        .overlay {
            if meetings.meetings.isEmpty, !meetings.isActive {
                ContentUnavailableView(
                    "No meetings yet", systemImage: "person.2.wave.2",
                    description: Text("Record a meeting in the room. Legato transcribes it as it goes and writes a summary afterwards."))
            }
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await meetings.start()
                        showsLive = meetings.isRecording
                    }
                } label: {
                    Label("Start meeting", systemImage: "record.circle")
                }
                .disabled(meetings.isActive || controller.isDictating)
                .accessibilityIdentifier("meetings.start")
            }
        }
        .navigationDestination(isPresented: $showsLive) { MeetingLiveView(controller: controller) }
        .task { await meetings.refresh() }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                Text(Self.duration(meeting.duration))
                if busy || meeting.state == .processing || meeting.state == .interrupted {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
