import LegatoMeetings
import SwiftUI

/// The Meetings window: the list; a meeting opens in place of it with a way back. A recording meeting opens
/// itself, and a meeting that is still starting shows its progress.
struct MeetingsWindow: View {
    @Environment(MacAppController.self) private var app
    @State private var selection: UUID?

    private var meetings: MeetingController { app.meetings }

    var body: some View {
        VStack(spacing: 0) {
            globalNotices
            content
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await meetings.refresh() }
        .onChange(of: meetings.liveMeetingID) { _, id in
            if let id { selection = id }
        }
        .onAppear { if let id = meetings.liveMeetingID { selection = id } }
    }

    /// What went wrong with the app itself (a meeting that did not start), above the list or the open meeting, until dismissed.
    @ViewBuilder private var globalNotices: some View {
        ForEach(meetings.notices.global) { notice in
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(notice.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { meetings.dismissNotice(notice.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20).padding(.top, 10)
            .accessibilityIdentifier("meetings.notice")
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if meetings.phase == .starting {
                startingView
            } else if let id = selection {
                MeetingDetailView(meetingID: id, onBack: { selection = nil })
                    .id(id)
            } else {
                MeetingListView(selection: $selection)
            }
        }
    }

    /// While the speech model loads (minutes the first time), with a way out.
    private var startingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting meeting…").font(.headline)
            Text("Loading the speech model — the first time can take a few minutes.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { meetings.cancelStart() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}
