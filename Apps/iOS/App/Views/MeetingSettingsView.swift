import LegatoAppServices
import LegatoMeetings
import LegatoModels
import SwiftUI

/// Settings > Meetings: summary templates and backend, language, speakers, processing, the noise filter,
/// the after-meeting pass, and the optional Claude key.
struct MeetingSettingsView: View {
    let controller: AppController

    @State private var backend = CleanupBackendChoice.auto
    @State private var noiseFilter = true
    @State private var liveDiarization = true
    @State private var offlineDiarization = true
    @State private var idleProcessing = true
    @State private var language: String?
    @State private var picked: [ModelRole: String] = [:]
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var keyError: String?
    @State private var postPass: String?
    @State private var pending: String?
    @State private var failures: [String: String] = [:]

    private var meetings: MeetingController { controller.meetings }
    private var models: ModelServices { controller.models }

    var body: some View {
        Form {
            MeetingTemplatesSection(settings: meetings.settings)

            Section {
                Picker("Backend", selection: $backend) {
                    Text("Auto").tag(CleanupBackendChoice.auto)
                    Text("Apple Foundation Models").tag(CleanupBackendChoice.foundationModels)
                    Text("MLX model").tag(CleanupBackendChoice.mlx)
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("The automatic summary runs on this iPhone with the backend above (the MLX model is the one picked in Cleanup).")
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
            }

            Section {
                Toggle("Tell speakers apart while recording", isOn: $liveDiarization)
                Toggle("Re-check speakers after the meeting", isOn: $offlineDiarization)
                ForEach(models.catalog.filter { $0.kind == .speakersLive || $0.kind == .speakersBatch }) { modelRow($0) }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Speakers are named Speaker 1, 2, … You rename them in Assign speakers; two with the same name become one. The models download when you pick them.")
            }

            Section {
                Toggle("Finish when Legato is idle", isOn: $idleProcessing)
            } header: {
                Text("After-meeting processing")
            } footer: {
                Text("The transcript pass, the speaker check and the summary run when no meeting records and Legato is open; iOS can also run them later in the background. Process now in a meeting skips the wait. Off runs them right after the meeting.")
            }

            Section {
                Toggle("Noise filter", isOn: $noiseFilter)
                if noiseFilter {
                    ForEach(models.catalog.filter { $0.kind == .echoNoise }) { modelRow($0) }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Removes background noise from the meeting microphone on this iPhone (LocalVQE, no echo reference). On by default; the model downloads when you pick it.")
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
                }
                .foregroundStyle(.primary)
                ForEach(models.postPassModels) { descriptor in
                    ModelRow(
                        descriptor: descriptor, manager: models.manager,
                        isSelected: postPass == descriptor.id,
                        isPending: pending == descriptor.id, failure: failures[descriptor.id],
                        onCancel: { cancelPostPass(descriptor.id) }
                    ) { pickPostPass(descriptor.id) }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deletePostPass(descriptor.id) }
                    }
                }
            } header: {
                Text("After-meeting pass")
            } footer: {
                Text("Runs after you stop a meeting and re-reads the saved audio with this model, which is more accurate than the live text. It covers 25 European languages (bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, sk, sl, es, sv, ru, uk). Off keeps the live text. Picking a model downloads it first.")
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
            backend = meetings.settings.backend
            noiseFilter = meetings.settings.echoNoise != .off
            liveDiarization = meetings.settings.liveDiarization
            offlineDiarization = meetings.settings.offlineDiarization
            idleProcessing = meetings.settings.idleProcessing
            language = meetings.settings.language
            for role in [ModelRole.liveSpeakers, .meetingSpeakers, .echoNoiseCancellation] { picked[role] = models.selected(role) }
            hasKey = meetings.hasClaudeKey
            postPass = models.selected(.postPass)
        }
        .onChange(of: backend) { _, new in meetings.settings.backend = new }
        .onChange(of: noiseFilter) { _, new in meetings.settings.echoNoise = new ? .localVQE : .off }
        .onChange(of: liveDiarization) { _, new in meetings.settings.liveDiarization = new }
        .onChange(of: offlineDiarization) { _, new in meetings.settings.offlineDiarization = new }
        .onChange(of: idleProcessing) { _, new in meetings.settings.idleProcessing = new }
        .onChange(of: language) { _, new in meetings.language = new }
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

    /// A row for one of the meeting helper models: download by picking, swipe to delete and free the space.
    @ViewBuilder private func modelRow(_ descriptor: ModelDescriptor) -> some View {
        if let role = Self.role(of: descriptor) {
            ModelRow(
                descriptor: descriptor, manager: models.manager,
                isSelected: picked[role] == descriptor.id
                    || (picked[role] == nil && models.catalog.filter { $0.kind == descriptor.kind }.count == 1),
                isPending: pending == descriptor.id, failure: failures[descriptor.id],
                onCancel: {
                    if pending == descriptor.id { pending = nil }
                    Task { await models.cancelDownload(descriptor.id) }
                },
                onPick: {
                    failures[descriptor.id] = nil
                    pending = descriptor.id
                    models.pick(descriptor.id, role: role) { error in
                        if pending == descriptor.id { pending = nil }
                        if let error { failures[descriptor.id] = String(describing: error) } else { picked[role] = models.selected(role) }
                    }
                }
            )
            .swipeActions {
                Button("Delete", role: .destructive) {
                    if pending == descriptor.id { pending = nil }
                    Task {
                        await models.manager.delete(descriptor.id)
                        picked[role] = models.selected(role)
                    }
                }
            }
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

/// Summary templates: the built-ins (read only), your own (add, edit, delete) and which one new meetings use.
private struct MeetingTemplatesSection: View {
    let settings: MeetingSettings

    private struct Draft: Identifiable {
        var id: String?
        var name: String
        var prompt: String
        var readOnly: Bool
        var key: String { id ?? "new" }
    }

    @State private var custom: [SummaryTemplate] = []
    @State private var defaultID = SummaryTemplate.summaryID
    @State private var draft: Draft?

    var body: some View {
        Section {
            ForEach(SummaryTemplate.builtIns + custom) { template in row(template) }
            Button { draft = Draft(id: nil, name: "", prompt: "", readOnly: false) } label: {
                Label("Add template", systemImage: "plus")
            }
            .accessibilityIdentifier("templates.add")
        } header: {
            Text("Summary templates")
        } footer: {
            Text("A template is the instruction the summary follows. The checked one is used for new meetings; each meeting can pick another. The built-in ones can be read, not changed.")
        }
        .onAppear(perform: reload)
        .sheet(item: $draft) { draft in
            TemplateEditor(draft: draft, onSave: { name, prompt in save(draft, name: name, prompt: prompt) }, onCancel: { self.draft = nil })
        }
    }

    private func row(_ template: SummaryTemplate) -> some View {
        HStack {
            Button { settings.defaultTemplateID = template.id; reload() } label: {
                Image(systemName: defaultID == template.id ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Use for new meetings")
            Button {
                draft = Draft(id: template.id, name: template.name, prompt: template.prompt, readOnly: template.isBuiltIn)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name).foregroundStyle(.primary)
                    if template.isBuiltIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
        }
        .swipeActions {
            if !template.isBuiltIn {
                Button("Delete", role: .destructive) { settings.deleteTemplate(id: template.id); reload() }
            }
        }
    }

    private func reload() {
        custom = settings.customTemplates
        defaultID = settings.defaultTemplateID
    }

    private func save(_ draft: Draft, name: String, prompt: String) {
        if let id = draft.id {
            settings.updateTemplate(SummaryTemplate(id: id, name: name, prompt: prompt))
        } else {
            settings.addTemplate(name: name, prompt: prompt)
        }
        self.draft = nil
        reload()
    }

    private struct TemplateEditor: View {
        let draft: Draft
        let onSave: (String, String) -> Void
        let onCancel: () -> Void
        @State private var name = ""
        @State private var prompt = ""

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Name", text: $name).disabled(draft.readOnly)
                    }
                    Section {
                        TextEditor(text: $prompt)
                            .font(.body.monospaced())
                            .frame(minHeight: 260)
                            .disabled(draft.readOnly)
                    } footer: {
                        Text("The language and your meeting notes are added automatically.")
                    }
                }
                .navigationTitle(draft.readOnly ? "Template" : draft.id == nil ? "New template" : "Edit template")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(draft.readOnly ? "Close" : "Cancel", action: onCancel) }
                    if !draft.readOnly {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), prompt) }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .onAppear {
                name = draft.name
                prompt = draft.prompt
            }
        }
    }
}
