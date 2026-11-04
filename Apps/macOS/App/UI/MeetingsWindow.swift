import LegatoMeetings
import SwiftUI

/// The Meetings window: folders and tags on the left, the meetings of the choice in the middle, one meeting on the
/// right. Recording starts and stops from the toolbar and from the menu bar.
struct MeetingsWindow: View {
    @Environment(MacAppController.self) private var app

    var body: some View {
        let controller = app.meetings
        @Bindable var bindable = controller
        NavigationSplitView {
            MeetingSidebar(meetings: controller.meetings, selection: $bindable.sidebar)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } content: {
            MeetingListColumn()
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 400)
        } detail: {
            if let meeting = controller.meeting(controller.selection) {
                MeetingDetailView(meeting: meeting).id(meeting.id)
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "waveform.and.mic",
                                       description: Text("Its summary, transcript and recording appear here."))
            }
        }
        .searchable(text: $bindable.query, placement: .toolbar, prompt: "Search meetings")
        .toolbar {
            ToolbarItem(placement: .navigation) { recordButton(controller) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = controller.notice {
                Banner(text: notice, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: controller.notice)
        .environment(controller)
        .tint(.purple)
        .frame(minWidth: 1000, idealWidth: 1180, minHeight: 600, idealHeight: 740)
        .task { await controller.refresh() }
        // A meeting the sidebar or the search filtered out is not shown on the right either.
        .onChange(of: controller.shown.map(\.id)) { _, ids in
            if let selection = controller.selection, !ids.contains(selection) { controller.selection = nil }
        }
    }

    @ViewBuilder private func recordButton(_ controller: MeetingController) -> some View {
        switch controller.phase {
        case .idle:
            Button { app.toggleMeeting() } label: { Label("Start Meeting", systemImage: "record.circle") }
                .tint(.red).help("Record the microphone and the audio your Mac plays")
        case .starting:
            ProgressView().controlSize(.small)
        case .recording:
            Button { app.toggleMeeting() } label: {
                Label("Stop \(MeetingListLogic.clock(controller.elapsed))", systemImage: "stop.circle.fill")
            }
            .tint(.red).help("Stop recording")
        case .stopping:
            ProgressView().controlSize(.small)
        }
    }
}
