import LegatoMeetings
import SwiftUI

/// The Meetings window: the list on the left; on the right the live view while recording, else the picked meeting.
struct MeetingsWindow: View {
    @Environment(MacAppController.self) private var app
    @State private var selection: UUID?

    private var meetings: MeetingController { app.meetings }

    var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await meetings.toggle() }
                } label: {
                    Label(meetings.phase == .recording ? "Stop meeting" : "Start meeting",
                          systemImage: meetings.phase == .recording ? "stop.circle.fill" : "record.circle")
                }
                .disabled(meetings.phase == .starting || meetings.phase == .stopping)
            }
        }
        .task { await meetings.refresh() }
        .onChange(of: meetings.phase) { _, phase in
            if phase == .recording { selection = nil }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if meetings.isRecording {
                Label(meetings.statusText, systemImage: "record.circle")
                    .foregroundStyle(.red)
            }
            ForEach(meetings.meetings.filter { $0.state != .recording || !meetings.isRecording }) { meeting in
                MeetingRow(meeting: meeting, busy: meetings.busy.contains(meeting.id))
                    .tag(meeting.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { Task { await meetings.delete(meeting) } }
                    }
            }
        }
        .overlay {
            if meetings.meetings.isEmpty, !meetings.isRecording {
                Text("No meetings yet.\nStart one from the toolbar or the menu bar.")
                    .multilineTextAlignment(.center)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if meetings.isRecording, selection == nil {
            MeetingLiveView()
        } else if let id = selection, let meeting = meetings.meetings.first(where: { $0.id == id }) {
            MeetingDetailView(meeting: meeting)
                .id(meeting.id)
        } else {
            Text("Select a meeting.").foregroundStyle(.secondary)
        }
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
