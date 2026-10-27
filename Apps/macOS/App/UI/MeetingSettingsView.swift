import LegatoAppServices
import LegatoMeetings
import LegatoModels
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
    @State private var postPass: String?
    @State private var pending: String?
    @State private var failures: [String: String] = [:]

    private var meetings: MeetingController { app.meetings }
    private var models: ModelServices { app.models }

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

            Section {
                Button {
                    pending = nil
                    models.clearPick(.postPass)
                    postPass = models.selected(.postPass)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Off")
                            Text("Keep the live text; nothing to download").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if postPass == nil { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(models.postPassModels) { descriptor in
                    ModelRow(
                        descriptor: descriptor, manager: models.manager,
                        isSelected: postPass == descriptor.id,
                        isPending: pending == descriptor.id, failure: failures[descriptor.id],
                        onPick: { pickPostPass(descriptor.id) }, onDelete: { deletePostPass(descriptor.id) },
                        onCancel: { cancelPostPass(descriptor.id) })
                }
            } header: {
                Text("After-meeting pass")
            } footer: {
                Text("Runs after you stop a meeting and re-reads the saved audio with this model, which is more accurate than the live text. It covers 25 European languages (bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, sk, sl, es, sv, ru, uk). Off keeps the live text. Picking a model downloads it first.")
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
        .frame(width: 520, height: 760)
        .onAppear {
            prompt = meetings.settings.customPrompt
            backend = meetings.settings.backend
            voiceProcessing = meetings.settings.voiceProcessing
            autoMute = meetings.settings.autoMute
            hasKey = meetings.hasClaudeKey
            postPass = models.selected(.postPass)
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

    private func pickPostPass(_ id: String) {
        failures[id] = nil
        pending = id
        models.pick(id, role: .postPass) { error in
            if pending == id { pending = nil }
            if let error { failures[id] = String(describing: error) } else { postPass = models.selected(.postPass) }
        }
    }

    private func cancelPostPass(_ id: String) {
        if pending == id { pending = nil }
        Task { await models.cancelDownload(id) }
    }

    private func deletePostPass(_ id: String) {
        if pending == id { pending = nil }
        Task {
            await models.manager.delete(id)
            postPass = models.selected(.postPass)
        }
    }
}
