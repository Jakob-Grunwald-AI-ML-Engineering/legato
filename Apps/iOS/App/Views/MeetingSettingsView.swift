import LegatoAppServices
import LegatoMeetings
import LegatoModels
import SwiftUI

/// Settings > Meetings: summary sections, when and with which backend the summary is written, language, speakers,
/// processing, the noise filter, the after-meeting pass, and the optional Claude key.
struct MeetingSettingsView: View {
    let controller: AppController

    @State private var backend = CleanupBackendChoice.foundationModels
    @State private var summarizeAutomatically = false
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

    private var selectedCleanupName: String {
        guard let id = models.selected(.cleanup), let model = models.cleanupModels.first(where: { $0.id == id }) else {
            return "Core ML model — choose in Cleanup"
        }
        return model.displayName
    }

    var body: some View {
        Form {
            MeetingSectionsSection(settings: meetings.settings)

            Section {
                Toggle("Summarize automatically after the meeting", isOn: $summarizeAutomatically)
                    .accessibilityIdentifier("settings.summarizeAutomatically")
                Picker("Summary model", selection: $backend) {
                    Text("Apple Foundation Models").tag(CleanupBackendChoice.foundationModels)
                    Text(selectedCleanupName).tag(CleanupBackendChoice.coreML)
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Off: each meeting has a Summarize button, so you can name the speakers first. On: the summary is written once the other after-meeting steps are done. The chosen model is used for every summary. Core ML uses the model selected in Cleanup; prepare it in Legato first. An unavailable model never switches to Apple Foundation Models.")
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
                Text("The transcript pass, the speaker check (and the summary, when it is automatic) run when no meeting records and Legato is open; iOS can also run them later in the background. Process now in a meeting skips the wait. Off runs them right after the meeting.")
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
            summarizeAutomatically = meetings.settings.summarizeAutomatically
            noiseFilter = meetings.settings.echoNoise != .off
            liveDiarization = meetings.settings.liveDiarization
            offlineDiarization = meetings.settings.offlineDiarization
            idleProcessing = meetings.settings.idleProcessing
            language = meetings.settings.language
            for role in [ModelRole.liveSpeakers, .meetingSpeakers, .echoNoiseCancellation] { picked[role] = models.selected(role) }
            hasKey = meetings.hasClaudeKey
            postPass = models.selected(.postPass)
        }
        .onChange(of: backend) { _, new in meetings.settings.backend = new; controller.meetingSettingsChanged() }
        .onChange(of: summarizeAutomatically) { _, new in meetings.settings.summarizeAutomatically = new }
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

/// Summary sections: the built-ins (read only), your own (add, edit, delete), their order in the summary, and which
/// are ticked for new meetings.
private struct MeetingSectionsSection: View {
    let settings: MeetingSettings

    private struct Draft: Identifiable {
        var id: String?
        var heading: String
        var instruction: String
        var readOnly: Bool
        var key: String { id ?? "new" }
    }

    @State private var all: [SummarySection] = []
    @State private var ticked: Set<SectionID> = []
    @State private var draft: Draft?

    var body: some View {
        Section {
            ForEach(Array(all.enumerated()), id: \.element.id) { index, section in row(section, at: index) }
            Button { draft = Draft(id: nil, heading: "", instruction: "", readOnly: false) } label: {
                Label("Add section", systemImage: "plus")
            }
            .accessibilityIdentifier("sections.add")
        } header: {
            Text("Summary sections")
        } footer: {
            Text("A summary holds the ticked sections, each under its heading, in this order. New meetings tick the checked ones; each meeting can tick others above its summary. Touch and hold a section to move it. The built-in ones can be read, not changed.")
        }
        .onAppear(perform: reload)
        .sheet(item: $draft) { draft in
            SectionEditor(
                draft: draft, onSave: { heading, instruction in save(draft, heading: heading, instruction: instruction) },
                onCancel: { self.draft = nil })
        }
    }

    private func row(_ section: SummarySection, at index: Int) -> some View {
        let on = ticked.contains(section.id)
        return HStack {
            Button { setDefault(section.id, !on) } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(on ? "Ticked for new meetings" : "Not ticked for new meetings")
            .accessibilityIdentifier("sections.default.\(section.id)")
            Button {
                draft = Draft(id: section.id, heading: section.heading, instruction: section.instruction, readOnly: section.isBuiltIn)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.heading).foregroundStyle(.primary)
                    if section.isBuiltIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
        }
        .contextMenu {
            Button { move(index, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }.disabled(index == 0)
            Button { move(index, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }.disabled(index == all.count - 1)
            if !section.isBuiltIn {
                Button(role: .destructive) { settings.deleteSection(id: section.id); reload() } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .swipeActions {
            if !section.isBuiltIn {
                Button("Delete", role: .destructive) { settings.deleteSection(id: section.id); reload() }
            }
        }
        .accessibilityAction(named: "Move up") { move(index, by: -1) }
        .accessibilityAction(named: "Move down") { move(index, by: 1) }
    }

    private func setDefault(_ id: SectionID, _ on: Bool) {
        var ids = Set(settings.defaultSectionIDs)
        if on { ids.insert(id) } else { ids.remove(id) }
        settings.defaultSectionIDs = Array(ids)
        reload()
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard all.indices.contains(target) else { return }
        settings.moveSections(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
        reload()
    }

    private func reload() {
        all = settings.allSections
        ticked = Set(settings.defaultSectionIDs)
    }

    private func save(_ draft: Draft, heading: String, instruction: String) {
        if let id = draft.id {
            settings.updateSection(SummarySection(id: id, heading: heading, instruction: instruction))
        } else {
            settings.addSection(heading: heading, instruction: instruction)
        }
        self.draft = nil
        reload()
    }

    private struct SectionEditor: View {
        let draft: Draft
        let onSave: (String, String) -> Void
        let onCancel: () -> Void
        @State private var heading = ""
        @State private var instruction = ""

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Heading", text: $heading).disabled(draft.readOnly)
                    }
                    Section {
                        TextEditor(text: $instruction)
                            .font(.body.monospaced())
                            .frame(minHeight: 200)
                            .disabled(draft.readOnly)
                    } footer: {
                        Text("What to write under the heading. The language, the speakers' names and your meeting notes are added automatically.")
                    }
                }
                .navigationTitle(draft.readOnly ? "Section" : draft.id == nil ? "New section" : "Edit section")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(draft.readOnly ? "Close" : "Cancel", action: onCancel) }
                    if !draft.readOnly {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { onSave(heading.trimmingCharacters(in: .whitespacesAndNewlines), instruction) }
                                .disabled(
                                    heading.trimmingCharacters(in: .whitespaces).isEmpty
                                        || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .onAppear {
                heading = draft.heading
                instruction = draft.instruction
            }
        }
    }
}
