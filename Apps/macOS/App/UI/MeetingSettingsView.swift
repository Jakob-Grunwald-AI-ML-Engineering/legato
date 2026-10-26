import LegatoAppServices
import LegatoMeetings
import SwiftUI

/// Settings > Meetings: the summary prompt and backend, echo handling, mute, and the optional Claude key.
struct MeetingSettingsView: View {
    @Environment(MacAppController.self) private var app

    @State private var prompt = ""
    @State private var backend = CleanupBackendChoice.auto
    @State private var voiceProcessing = true
    @State private var autoMute = true
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var keyError: String?

    private var meetings: MeetingController { app.meetings }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(height: 120)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("Default: Summary, Decisions, Action items.")
                                .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                Picker("Backend", selection: $backend) {
                    Text("Auto").tag(CleanupBackendChoice.auto)
                    Text("Apple Foundation Models").tag(CleanupBackendChoice.foundationModels)
                    Text("MLX model").tag(CleanupBackendChoice.mlx)
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Your instructions replace the default prompt for the automatic summary after a meeting. It runs on this Mac with the backend above (the MLX model is the one picked in Cleanup).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Toggle("Echo cancellation (voice processing)", isOn: $voiceProcessing)
                Toggle("Mute me automatically when the call app mutes", isOn: $autoMute)
                LabeledContent("Mute hotkey") { HotkeyRecorderView(target: .mute) }
            }

            Section {
                SecureField("Claude API key", text: $keyDraft)
                    .textContentType(.password)
                HStack {
                    Button("Save key") { saveKey() }.disabled(keyDraft.isEmpty)
                    if hasKey {
                        Button("Remove key", role: .destructive) { keyDraft = ""; _ = meetings.saveClaudeKey(""); hasKey = meetings.hasClaudeKey }
                        Label("Key stored in the Keychain", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                    }
                }
                if let keyError { Text(keyError).font(.callout).foregroundStyle(.red) }
            } header: {
                Text("Claude (optional)")
            } footer: {
                Text("Used only when you choose Summarize with Claude on a meeting; that sends the transcript to Anthropic. Never automatic.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear {
            prompt = meetings.settings.customPrompt
            backend = meetings.settings.backend
            voiceProcessing = meetings.settings.voiceProcessing
            autoMute = meetings.settings.autoMute
            hasKey = meetings.hasClaudeKey
        }
        .onChange(of: prompt) { _, new in meetings.settings.customPrompt = new }
        .onChange(of: backend) { _, new in meetings.settings.backend = new }
        .onChange(of: voiceProcessing) { _, new in meetings.settings.voiceProcessing = new }
        .onChange(of: autoMute) { _, new in meetings.settings.autoMute = new }
    }

    private func saveKey() {
        keyError = meetings.saveClaudeKey(keyDraft)
        if keyError == nil { keyDraft = "" }
        hasKey = meetings.hasClaudeKey
    }
}
