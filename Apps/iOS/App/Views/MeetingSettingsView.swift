import LegatoAppServices
import SwiftUI

/// Settings > Meetings: the summary prompt and backend, and the optional Claude key.
struct MeetingSettingsView: View {
    let controller: AppController

    @State private var prompt = ""
    @State private var backend = CleanupBackendChoice.auto
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var keyError: String?

    private var meetings: MeetingController { controller.meetings }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
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
                Text("Your instructions replace the default prompt for the automatic summary after a meeting. It runs on this iPhone with the backend above (the MLX model is the one picked in Cleanup).")
            }

            Section {
                SecureField("Claude API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") { saveKey() }.disabled(keyDraft.isEmpty)
                if hasKey {
                    Label("Key stored in the Keychain", systemImage: "checkmark").foregroundStyle(.green)
                    Button("Remove key", role: .destructive) {
                        keyDraft = ""
                        _ = meetings.saveClaudeKey("")
                        hasKey = meetings.hasClaudeKey
                    }
                }
                if let keyError { Text(keyError).font(.callout).foregroundStyle(.red) }
            } header: {
                Text("Claude (optional)")
            } footer: {
                Text("Used only when you choose Summarize with Claude on a meeting; that sends the transcript to Anthropic. Never automatic. The key stays in this iPhone's Keychain.")
            }
        }
        .navigationTitle("Meetings")
        .onAppear {
            prompt = meetings.settings.customPrompt
            backend = meetings.settings.backend
            hasKey = meetings.hasClaudeKey
        }
        .onChange(of: prompt) { _, new in meetings.settings.customPrompt = new }
        .onChange(of: backend) { _, new in meetings.settings.backend = new }
    }

    private func saveKey() {
        keyError = meetings.saveClaudeKey(keyDraft)
        if keyError == nil { keyDraft = "" }
        hasKey = meetings.hasClaudeKey
    }
}
