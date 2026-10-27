import LegatoAppServices
import LegatoMeetings
import LegatoModels
import SwiftUI

/// Settings > Meetings: summary templates and backend, speakers, processing, language, echo and noise, mute, and the optional Claude key.
struct MeetingSettingsView: View {
    @Environment(MacAppController.self) private var app

    @State private var backend = CleanupBackendChoice.auto
    @State private var echoNoise = EchoNoiseMode.localVQE
    @State private var liveDiarization = true
    @State private var offlineDiarization = true
    @State private var idleProcessing = true
    @State private var language: String?
    @State private var picked: [ModelRole: String] = [:]
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
            MeetingTemplatesView(settings: meetings.settings)

            Section {
                Picker("Backend", selection: $backend) {
                    Text("Auto").tag(CleanupBackendChoice.auto)
                    Text("Apple Foundation Models").tag(CleanupBackendChoice.foundationModels)
                    Text("MLX model").tag(CleanupBackendChoice.mlx)
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("The automatic summary runs on this Mac with the backend above (the MLX model is the one picked in Cleanup).")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Picker("Default language", selection: $language) {
                    Text("Auto").tag(String?.none)
                    ForEach(MeetingListView.languages, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Each meeting can pick its own in the list's toolbar; the last one used is remembered. Auto lets the speech model choose.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tell speakers apart while recording", isOn: $liveDiarization)
                Toggle("Re-check speakers after the meeting", isOn: $offlineDiarization)
                ForEach(models.catalog.filter { $0.kind == .speakersLive || $0.kind == .speakersBatch }) { modelRow($0) }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Speakers are named Speaker 1, 2, … You rename them in Assign speakers; two with the same name become one. The models download when you pick them.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Wait until the Mac is idle", isOn: $idleProcessing)
            } header: {
                Text("After-meeting processing")
            } footer: {
                Text("The transcript pass, the speaker check and the summary run when no meeting records and the Mac is quiet. Process now in a meeting skips the wait. Off runs them right after the meeting.")
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
                Picker("Echo & noise cancellation", selection: $echoNoise) {
                    Text("LocalVQE").tag(EchoNoiseMode.localVQE)
                    Text("Apple voice processing").tag(EchoNoiseMode.appleVoiceProcessing)
                    Text("Off").tag(EchoNoiseMode.off)
                }
                if echoNoise == .localVQE {
                    ForEach(models.catalog.filter { $0.kind == .echoNoise }) { modelRow($0) }
                }
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
        .frame(width: 540, height: 760)
        .onAppear {
            backend = meetings.settings.backend
            echoNoise = meetings.settings.echoNoise
            liveDiarization = meetings.settings.liveDiarization
            offlineDiarization = meetings.settings.offlineDiarization
            idleProcessing = meetings.settings.idleProcessing
            language = meetings.settings.language
            for role in [ModelRole.liveSpeakers, .meetingSpeakers, .echoNoiseCancellation] { picked[role] = models.selected(role) }
            autoMute = meetings.settings.autoMute
            hasKey = meetings.hasClaudeKey
            postPass = models.selected(.postPass)
        }
        .onChange(of: backend) { _, new in meetings.settings.backend = new }
        .onChange(of: echoNoise) { _, new in meetings.settings.echoNoise = new }
        .onChange(of: liveDiarization) { _, new in meetings.settings.liveDiarization = new }
        .onChange(of: offlineDiarization) { _, new in meetings.settings.offlineDiarization = new }
        .onChange(of: idleProcessing) { _, new in meetings.settings.idleProcessing = new }
        .onChange(of: language) { _, new in
            meetings.settings.language = new
            meetings.language = new
        }
        .onChange(of: autoMute) { _, new in meetings.settings.autoMute = new }
    }

    // MARK: Model rows

    private static func role(of descriptor: ModelDescriptor) -> ModelRole? {
        switch descriptor.kind {
        case .speakersLive: .liveSpeakers
        case .speakersBatch: .meetingSpeakers
        case .echoNoise: .echoNoiseCancellation
        default: nil
        }
    }

    /// A row for one of the meeting helper models: download by picking, delete to free the space.
    @ViewBuilder private func modelRow(_ descriptor: ModelDescriptor) -> some View {
        if let role = Self.role(of: descriptor) {
            ModelRow(
                descriptor: descriptor, manager: models.manager,
                isSelected: picked[role] == descriptor.id
                    || (picked[role] == nil && models.catalog.filter { $0.kind == descriptor.kind }.count == 1),
                isPending: pending == descriptor.id, failure: failures[descriptor.id],
                onPick: {
                    failures[descriptor.id] = nil
                    pending = descriptor.id
                    models.pick(descriptor.id, role: role) { error in
                        if pending == descriptor.id { pending = nil }
                        if let error { failures[descriptor.id] = String(describing: error) } else { picked[role] = models.selected(role) }
                    }
                },
                onDelete: {
                    if pending == descriptor.id { pending = nil }
                    Task {
                        await models.manager.delete(descriptor.id)
                        picked[role] = models.selected(role)
                    }
                },
                onCancel: {
                    if pending == descriptor.id { pending = nil }
                    Task { await models.cancelDownload(descriptor.id) }
                })
        }
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
