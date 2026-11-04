import LegatoMeetings
import SwiftUI

/// The meetings of the sidebar's choice, newest first under their day.
struct MeetingListColumn: View {
    @Environment(MeetingController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        let days = MeetingListLogic.groupByDay(controller.shown)
        List(selection: $controller.selection) {
            ForEach(days, id: \.day) { day in
                Section(MeetingListLogic.dayLabel(day.day)) {
                    ForEach(day.meetings) { meeting in
                        MeetingRow(meeting: meeting, processing: controller.services.processing.contains(meeting.id),
                                   summarizing: controller.services.summarizing.contains(meeting.id))
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Delete…", role: .destructive) { pendingDelete = meeting.id }
                                    .disabled(meeting.id == controller.services.activeMeetingID)
                            }
                    }
                }
            }
        }
        .overlay { if days.isEmpty { empty } }
        .confirmationDialog("Delete this meeting?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) {
                if let id = pendingDelete { controller.delete(id) }
                pendingDelete = nil
            }
        } message: {
            Text("The transcript, summary and audio are removed from this Mac.")
        }
    }

    @State private var pendingDelete: UUID?

    @ViewBuilder private var empty: some View {
        if !controller.query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: controller.query)
        } else if controller.meetings.isEmpty {
            Text("No meetings").foregroundStyle(.secondary)
        } else {
            ContentUnavailableView("Nothing here", systemImage: "folder", description: Text("No meeting is filed under this."))
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let processing: Bool
    let summarizing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(meeting.title).font(.headline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                badge
            }
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 56, alignment: .leading)
        .listRowInsets(EdgeInsets())
    }

    /// "9:10 · 42 min · Acme".
    private var subtitle: String {
        [MeetingFormat.time(meeting.date), MeetingFormat.length(meeting.duration), meeting.client ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        if meeting.state == .recording {
            Label("Recording", systemImage: "circle.fill").labelStyle(.iconOnly).font(.system(size: 8)).foregroundStyle(.red)
        } else if summarizing || processing || meeting.state == .processing {
            ProgressView().controlSize(.mini)
        } else if meeting.state == .interrupted {
            Text("Interrupted").font(.caption).foregroundStyle(.orange)
        } else if meeting.summaryFailure != nil {
            Text("No summary").font(.caption).foregroundStyle(.orange)
        }
    }
}
