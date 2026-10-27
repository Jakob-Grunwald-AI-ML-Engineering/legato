import LegatoMeetings
import SwiftUI

/// The Meetings screen: the list, the way to start a meeting and its language, and the meeting document a
/// card opens. A meeting that starts opens its own document.
struct MeetingsView: View {
    let controller: AppController
    @State private var opened: UUID?

    private var meetings: MeetingController { controller.meetings }

    var body: some View {
        MeetingListView(controller: controller, opened: $opened)
            .navigationTitle("Meetings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { meetings.language = nil } label: {
                            if meetings.language == nil { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
                        }
                        Divider()
                        ForEach(MeetingListView.languages, id: \.id) { language in
                            Button { meetings.language = language.id } label: {
                                if meetings.language == language.id {
                                    Label(language.name, systemImage: "checkmark")
                                } else {
                                    Text(language.name)
                                }
                            }
                        }
                    } label: {
                        Label(languageName, systemImage: "globe")
                    }
                    .disabled(meetings.isActive)
                    .accessibilityIdentifier("meetings.language")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await meetings.start()
                            if meetings.isRecording { opened = meetings.liveMeetingID }
                        }
                    } label: {
                        if meetings.phase == .starting {
                            ProgressView()  // the model loads and the audio session opens: the tap did something
                        } else {
                            Label("Start meeting", systemImage: "plus")
                        }
                    }
                    .disabled(meetings.isActive || controller.isDictating)
                    .accessibilityIdentifier("meetings.start")
                }
            }
            .navigationDestination(item: $opened) { id in
                MeetingDetailView(controller: controller, meetingID: id, onClose: { opened = nil })
            }
            .task { await meetings.refresh() }
    }

    private var languageName: String {
        meetings.language.flatMap { id in MeetingListView.languages.first { $0.id == id }?.name ?? id } ?? "Auto"
    }
}
