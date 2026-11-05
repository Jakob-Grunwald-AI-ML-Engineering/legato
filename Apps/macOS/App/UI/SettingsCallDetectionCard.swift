import LegatoAppServices
import SwiftUI

/// Settings, Meetings: what Legato does when another app starts a call. Off means nothing watches the microphone.
struct SettingsCallDetectionCard: View {
    private let settings = MeetingSettings(defaults: .standard)
    @State private var mode = CallDetectionMode.off

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Calls", systemImage: "phone.fill").font(.headline)
                Picker("When another app starts a call", selection: $mode) {
                    Text("Off").tag(CallDetectionMode.off)
                    Text("Ask").tag(CallDetectionMode.prompt)
                    Text("Record").tag(CallDetectionMode.autoRecord)
                }
                .pickerStyle(.segmented).fixedSize()
                .accessibilityIdentifier("settings.calls.mode")
                Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { mode = settings.callDetection }
        .onChange(of: mode) { _, value in settings.callDetection = value }
    }

    private var explanation: String {
        switch mode {
        case .off: "Legato does not watch for calls."
        case .prompt: "When another app uses the microphone and the speakers together, a small card offers to record the call as a meeting."
        case .autoRecord:
            "A call starts a meeting by itself and ends it about 10 seconds after the call is over. A meeting you start yourself, "
                + "also from the card, is never ended this way."
        }
    }
}
