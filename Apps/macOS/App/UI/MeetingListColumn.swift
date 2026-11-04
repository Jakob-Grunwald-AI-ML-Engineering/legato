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
            ContentUnavailableView("No meetings yet", systemImage: "waveform.badge.mic",
                                   description: Text("Start a meeting from the menu bar or the button above. Legato listens to your microphone and to the audio your Mac plays."))
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if meeting.state == .recording { Circle().fill(.red).frame(width: 8, height: 8) }
                Text(meeting.title).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(meeting.date.formatted(date: .omitted, time: .shortened))
                if meeting.duration > 0 { Text("·"); Text(MeetingListLogic.clock(meeting.duration)) }
                if let status { Text("·"); status }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let filing {
                Text(filing).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var filing: String? {
        let folder = [meeting.client, meeting.project].compactMap { $0 }.joined(separator: " / ")
        let line = ([folder] + meeting.tags.map { "#\($0)" }).filter { !$0.isEmpty }.joined(separator: "  ")
        return line.isEmpty ? nil : line
    }

    private var status: Text? {
        if meeting.state == .recording { return Text("Recording").foregroundStyle(.red) }
        if summarizing { return Text("Summarizing…") }
        if processing || meeting.state == .processing { return Text("Finishing…") }
        if meeting.state == .interrupted { return Text("Interrupted").foregroundStyle(.orange) }
        if meeting.summaryFailure != nil { return Text("No summary").foregroundStyle(.orange) }
        return nil
    }
}
