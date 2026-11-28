import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LegatoAppServices
import LegatoClaude
import LegatoAgent
import LegatoMac

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview", voice = "Voice", writing = "Writing", meetings = "Meetings", keys = "API Keys", shortcut = "Shortcut"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .voice: "person.wave.2"
            case .overview: "sparkles"
            case .writing: "text.alignleft"
            case .meetings: "person.2.wave.2"
            case .keys: "key.horizontal"
            case .shortcut: "command"
            }
        }
        var subtitle: String {
            switch self {
            case .voice: "Choose the microphone and quietly reduce background voices."
            case .overview: "Your voice, ready to write."
            case .writing: "Shape text where you write."
            case .meetings: "Record, transcribe and summarize your calls."
            case .keys: "Connect transcription and Magic."
            case .shortcut: "Dictate and use Magic anywhere on your Mac."
            }
        }
    }
    @Environment(MacAppController.self) private var controller
    @AppStorage(ComposerWritingSettings.modelKey) private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage(ComposerWritingSettings.promptKey) private var personalPrompt = ""
    @State private var page: Page? = .overview
    @State private var claudeKey = ""
    @State private var sonioxKey = ""
    @State private var claudeSaved = false
    @State private var sonioxSaved = false
    @State private var keyNotice = ""
    @State private var keyError = false
    private var currentPage: Page { page ?? .overview }
    private var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.weight(.semibold)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Legato").font(.headline)
                        Text("Dictation & Magic").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 24)
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5).tag(item)
                }.listStyle(.sidebar)
                Text("Made for your flow.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 20)
            }.navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(currentPage.rawValue).font(.largeTitle.weight(.bold))
                        Text(currentPage.subtitle).foregroundStyle(.secondary)
                    }
                    switch currentPage {
                    case .voice: VStack(alignment: .leading, spacing: 20) { DictationMicrophoneCard(); VoiceSettingsSection() }
                    case .overview: overview
                    case .writing: writing
                    case .meetings: SettingsMeetingsPage()
                    case .keys: keys
                    case .shortcut: shortcut
                    }
                }.frame(maxWidth: 640, alignment: .leading).padding(32).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.purple)
        .frame(minWidth: 740, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .task { refreshKeys(); controller.permissions.refresh() }
        .onChange(of: page) { _, _ in controller.cancelRecording(); controller.permissions.refresh() }
        .onDisappear { controller.cancelRecording() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Speak. Shape. Send.").font(.title2.weight(.semibold))
                        Text("Dictate into a draft beside the cursor. Click Magic to revise the whole draft, then Insert when you’re ready.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("SETUP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    readiness("Writing & transcription", detail: "Claude writes your text. Soniox transcribes your voice.", ready: claudeSaved && sonioxSaved, action: "Manage keys") { page = .keys }
                    Divider()
                    readiness("Global shortcuts", detail: "Magic \(controller.settings.hotkey?.displayName ?? "not set"), dictation \(controller.settings.dictationHotkey?.displayName ?? "not set").", ready: controller.settings.hotkey != nil && controller.settings.dictationHotkey != nil, action: "Edit shortcuts") { page = .shortcut }
                }
            }
            permissions
        }
    }
    private var writing: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Writing model", systemImage: "sparkles").font(.headline)
                    Picker("Writing model", selection: $liveModel) {
                        ForEach(ModelChoice.allCases, id: \.rawValue) { model in
                            Text(modelName(model)).tag(model.rawValue)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Magic uses this model to revise your draft.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Personal instructions").font(.headline)
                    Text("Add your preferred tone, spelling, or formatting. Magic follows them when editing your text.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ZStack(alignment: .topLeading) {
                        if personalPrompt.isEmpty {
                            Text("For example: Use British spelling and keep sentences concise.")
                                .foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.vertical, 8).allowsHitTesting(false)
                        }
                        TextEditor(text: $personalPrompt).font(.body).scrollContentBackground(.hidden)
                            .padding(4).accessibilityLabel("Personal instructions")
                    }.frame(minHeight: 190).background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    Label("Changes save automatically and apply to your next instruction.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var keys: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 20) {
                    provider("Claude", detail: "Writing and corrections", saved: claudeSaved, key: $claudeKey)
                    Divider()
                    provider("Soniox", detail: "Voice transcription", saved: sonioxSaved, key: $sonioxKey)
                }
            }
            HStack {
                Label("Stored securely in this Mac’s Keychain.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save keys", action: saveKeys).buttonStyle(.borderedProminent)
            }
            Text("Enter only the keys you want to add or replace. Blank fields keep saved keys. Saved keys are never displayed here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !keyNotice.isEmpty {
                Label(keyNotice, systemImage: keyError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(keyError ? Color.orange : Color.secondary)
                    .accessibilityLabel(keyNotice)
            }
            Text("Saved means a key is present in Keychain; it does not verify the provider account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var insertionSettings: some View {
        @Bindable var settings = controller.settings
        return card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Insert draft", systemImage: "text.cursor").font(.headline)
                Toggle("Typewriter animation on insertion", isOn: $settings.typewriter)
                Toggle("Restore clipboard after a paste", isOn: $settings.restoreClipboard)

            }
        }
    }
    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Magic shortcut", systemImage: "command").font(.headline)
                    HotkeyRecorderView(target: .magic)
                    Text("Tap to revise the draft. Hold to speak an instruction, then release to apply it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Dictation shortcut", systemImage: "mic").font(.headline)
                    HotkeyRecorderView(target: .dictation)
                    Text("Tap to start or stop, or hold to talk. Pausing and stopping leave your words in the composer.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Composer shortcuts", systemImage: "keyboard").font(.headline)
                    ForEach(MacComposerShortcut.chordActions, id: \.self) { shortcut in
                        Divider()
                        Text(shortcut.actionTitle).font(.body.weight(.medium))
                        HotkeyRecorderView(target: .composer(shortcut))
                    }
                }
            }
            insertionSettings
            permissions
        }
    }
    private var permissions: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Mac permissions").font(.headline)
                    Spacer()
                    Button { controller.permissions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh permission status").accessibilityLabel("Refresh permission status")
                }
                readiness("Microphone", detail: "Capture dictation and spoken instructions.", ready: controller.permissions.micGranted, action: "Allow microphone") { Task { await controller.permissions.requestMicrophone() } }
                Divider()
                readiness("Accessibility", detail: "Read and edit the focused field safely.", ready: controller.permissions.accessibility, action: "Open Settings") { controller.permissions.requestAccessibility() }
                Divider()
                readiness("Input Monitoring", detail: "Listen for your shortcut outside Legato.", ready: inputMonitoringGranted, action: "Open Settings") { controller.permissions.requestInputMonitoring() }
            }
        }
    }
    private func readiness(_ title: String, detail: String, ready: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary).accessibilityLabel(ready ? "Ready" : "Needs setup")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if title == "Microphone" || title == "Accessibility" || title == "Input Monitoring" {
                if ready { Text("Allowed").font(.caption).foregroundStyle(.secondary) }
                else { Button(action, action: perform).controlSize(.small) }
            } else { Button(action, action: perform).controlSize(.small) }
        }
    }
    private func provider(_ name: String, detail: String, saved: Bool, key: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(saved ? "Saved" : "Not added", systemImage: saved ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption).foregroundStyle(saved ? Color.green : Color.secondary)
            }
            SecureField(saved ? "Enter replacement key" : "Enter API key", text: key)
                .textFieldStyle(.roundedBorder).accessibilityLabel("\(name) API key")
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        SettingsCard { content() }
    }
    private func modelName(_ model: ModelChoice) -> String {
        switch model { case .haiku: "Claude Haiku 5.5"; case .sonnet: "Claude Sonnet 5.5"; case .opus: "Claude Opus 5.5" }
    }
    private func refreshKeys() {
        do {
            claudeSaved = try KeychainKeyStore().apiKey()?.isEmpty == false
            sonioxSaved = try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()?.isEmpty == false
        } catch { keyError = true; keyNotice = "Could not read Keychain. Try again after unlocking your Mac." }
    }
    private func saveKeys() {
        do {
            let claude = claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let soniox = sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !claude.isEmpty { try KeychainKeyStore().save(apiKey: claude) }
            if !soniox.isEmpty { try KeychainKeyStore(service: "de.gruenwald.legato.soniox").save(apiKey: soniox) }
            claudeKey = ""; sonioxKey = ""; keyError = false
            keyNotice = claude.isEmpty && soniox.isEmpty ? "Saved keys kept unchanged." : "Keys saved on this Mac."
            refreshKeys()
        } catch { keyError = true; keyNotice = "Could not save keys. Your entries are kept here so you can try again." }
    }
}

/// Settings → Voice: Reduce background voices, the guided setup, recorded settings and kept recordings. Its own view,
/// so recording progress and list changes redraw only this section, never the whole settings window.
private struct VoiceSettingsSection: View {
    @Environment(MacAppController.self) private var controller
    @AppStorage("voiceIsolation.enabled") private var onlyMyVoice = false
    @State private var enrollment = VoiceEnrollmentController.shared
    @State private var addingSetting = false
    @State private var newSettingName = ""
    @State private var confirmingDelete = false
    @State private var confirmingDeleteRecordings = false

    var body: some View {
        @Bindable var enrollment = enrollment
        let microphoneBusy: @MainActor () -> Bool = { controller.dictation.isActive || controller.meetings.isRecording }
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Background voices", systemImage: "person.wave.2").font(.headline)
                    Toggle(VoiceSetupCopy.toggle, isOn: enrollment.optionBinding($onlyMyVoice))
                        .disabled(enrollment.isBusy)
                        .accessibilityIdentifier("settings.onlyMyVoice")
                    Text(enrollment.hasProfile ? VoiceSetupCopy.saved : VoiceSetupCopy.notSetUp)
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !enrollment.hasProfile {
                        Button(VoiceSetupCopy.setupButton) { enrollment.startFirstSetup(microphoneBusy: microphoneBusy) }
                            .disabled(enrollment.isBusy).accessibilityIdentifier("settings.setUpVoice")
                    }
                    notice(.voice)
                    Text(VoiceSetupCopy.about).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if enrollment.hasProfile {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(VoiceSetupCopy.settingsHeader).font(.headline)
                        Text(VoiceSetupCopy.settingsAbout).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(enrollment.situations) { row in
                            Divider()
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.name).font(.body.weight(.medium))
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if row.isCustom {
                                    Button { enrollment.deleteSituation(id: row.id) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("Delete \(row.name)").accessibilityLabel("Delete \(row.name)")
                                        .disabled(enrollment.isBusy).accessibilityIdentifier("settings.deleteSetting.\(row.id)")
                                }
                                Button(VoiceSetupCopy.recordButton(row)) { enrollment.record(situationID: row.id, microphoneBusy: microphoneBusy) }
                                    .controlSize(.small).disabled(enrollment.isBusy)
                                    .accessibilityIdentifier("settings.recordSetting.\(row.id)")
                            }
                        }
                        Divider()
                        Button(VoiceSetupCopy.addSetting) { newSettingName = ""; enrollment.clearNotice(); addingSetting = true }
                            .disabled(enrollment.isBusy).accessibilityIdentifier("settings.addSetting")
                        notice(.settings)
                    }
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(VoiceSetupCopy.keepRecordings, isOn: $enrollment.keepRecordings)
                        .accessibilityIdentifier("settings.keepVoiceRecordings")
                    Text(VoiceSetupCopy.recordingsAbout).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !enrollment.keepRecordings && !enrollment.recordings.isEmpty {
                        Text(VoiceSetupCopy.recordingsStay).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.voiceRecordingsStay")
                    }
                    if enrollment.recordings.isEmpty {
                        notice(.recordings)
                    } else {
                        HStack(spacing: 12) {
                            let all = enrollment.exportAll()
                            ShareLink(item: all, preview: all.preview) {
                                Label(VoiceSetupCopy.exportAll, systemImage: "square.and.arrow.up")
                            }.accessibilityIdentifier("settings.exportVoiceRecordings")
                            Button(VoiceSetupCopy.saveToFolder) { saveToFolder(all) }
                                .accessibilityIdentifier("settings.saveVoiceRecordings")
                            Spacer()
                            Button(VoiceSetupCopy.deleteRecordings, role: .destructive) { enrollment.clearNotice(); confirmingDeleteRecordings = true }
                                .disabled(enrollment.isBusy).accessibilityIdentifier("settings.deleteVoiceRecordings")
                        }
                        notice(.recordings)
                        ForEach(enrollment.recordings) { entry in
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(VoiceSetupCopy.recordingTitle(entry))
                                    Text(VoiceSetupCopy.recordingDetail(entry)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                let export = enrollment.export(entry)
                                Button { saveToFolder(export) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless).help(VoiceSetupCopy.saveToFolder).accessibilityLabel(VoiceSetupCopy.saveToFolder)
                                ShareLink(item: export, preview: export.preview) {
                                    Image(systemName: "square.and.arrow.up")
                                }.buttonStyle(.borderless).help(VoiceSetupCopy.shareRecording).accessibilityLabel(VoiceSetupCopy.shareRecording)
                            }
                        }
                    }
                }
            }
            if enrollment.hasProfile || !enrollment.recordings.isEmpty {
                HStack {
                    Text(VoiceSetupCopy.deleteVoiceAbout).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(VoiceSetupCopy.deleteVoice, role: .destructive) { enrollment.clearNotice(); confirmingDelete = true }
                        .disabled(enrollment.isBusy).accessibilityIdentifier("settings.deleteVoice")
                }
            }
        }
        .onAppear { enrollment.refresh() }
        .onDisappear { enrollment.cancel() }
        .sheet(isPresented: Binding(get: { enrollment.isGuidePresented }, set: { if !$0 { enrollment.closeGuide() } })) {
            VoiceRecordingGuideView(controller: enrollment).interactiveDismissDisabled()
        }
        .alert(VoiceSetupCopy.addSettingTitle, isPresented: $addingSetting) {
            TextField(VoiceSetupCopy.addSettingPlaceholder, text: $newSettingName)
            Button("Add") { enrollment.addSituation(named: newSettingName) }
                .disabled(!VoiceSetupCopy.isValidSettingName(newSettingName))
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(VoiceSetupCopy.deleteRecordings, isPresented: $confirmingDeleteRecordings) {
            Button(VoiceSetupCopy.deleteRecordings, role: .destructive) { enrollment.deleteRecordings() }
        } message: { Text(VoiceSetupCopy.deleteRecordingsAbout) }
        .confirmationDialog(VoiceSetupCopy.deleteVoice, isPresented: $confirmingDelete) {
            Button(VoiceSetupCopy.deleteVoice, role: .destructive) { enrollment.deleteProfile(); onlyMyVoice = false }
        } message: { Text(VoiceSetupCopy.deleteVoiceAbout) }
    }

    @ViewBuilder private func notice(_ place: VoiceNotice.Place) -> some View {
        if let text = enrollment.notice(for: place) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.voiceNotice")
        }
    }

    /// Save to folder…: the zip goes where the user chooses, next to Share.
    private func saveToFolder(_ export: VoiceRecordingExport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = export.fileName
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enrollment.save(export, to: url)
    }
}
