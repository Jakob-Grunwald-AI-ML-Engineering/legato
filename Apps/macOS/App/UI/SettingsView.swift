import AppKit
import SwiftUI
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
            case .voice: "Quietly reduce background voices while you dictate."
            case .overview: "Your voice, ready to write."
            case .writing: "Shape text where you write."
            case .meetings: "Record, transcribe and summarize your calls."
            case .keys: "Connect transcription and Magic."
            case .shortcut: "Dictate and use Magic anywhere on your Mac."
            }
        }
    }
    @Environment(MacAppController.self) private var controller
    @AppStorage("composer.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("composer.personalPrompt") private var personalPrompt = ""
    @AppStorage(InstructionSendSetting.modeKey) private var instructionSend = InstructionSendSetting.Mode.manual.rawValue
    @AppStorage(InstructionSendSetting.pauseKey) private var instructionPause = InstructionSendSetting.defaultPause
    @AppStorage("voiceIsolation.enabled") private var onlyMyVoice = false
    @AppStorage(PanelDictationSetting.key) private var panelMode = PanelDictationSetting.defaultMode.rawValue
    @State private var enrollment = VoiceEnrollmentController.shared
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
                    case .voice: voice
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

    private var voice: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {

            Toggle("Reduce background voices (experimental)", isOn: $onlyMyVoice)
                .disabled(!enrollment.hasProfile || enrollment.isBusy)
                .accessibilityIdentifier("settings.onlyMyVoice")
            Text(enrollment.hasProfile ? "Voice profile saved on this device." : "Record your voice once to help reduce background voices.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Speak alone in a quiet place for ten seconds. Try: ‘Today I’m taking a moment to describe what I’m working on and what I’d like to do next. I want my writing to sound natural and clear.’")
                .font(.callout).foregroundStyle(.secondary)
            if enrollment.isBusy {
                if enrollment.isRecording { ProgressView(value: enrollment.progress) }
                else { ProgressView() }
                Text(enrollment.stage).font(.callout).accessibilityIdentifier("settings.voiceEnrollmentStatus")
                Button("Cancel", role: .cancel) { enrollment.cancel() }
            } else {
                Button(enrollment.hasProfile ? "Record replacement voice profile" : "Record voice profile") {
                    enrollment.record(microphoneBusy: { controller.dictation.isActive || controller.meetings.isRecording })
                }.accessibilityIdentifier("settings.recordVoiceProfile")
                if enrollment.hasProfile {
                    Button("Delete voice profile", role: .destructive) { enrollment.deleteProfile(); onlyMyVoice = false }
                        .accessibilityIdentifier("settings.deleteVoiceProfile")
                }
            }
            if let message = enrollment.message {
                Text(message).font(.callout).accessibilityIdentifier("settings.voiceEnrollmentMessage")
            }
            Text("Quietly reduces background voices while prioritizing your speech, without holding text back. Experimental: other voices may still get through. First setup downloads a model; only your voice profile is saved locally, not the recording. Changes apply to the next take. Meetings keep every speaker.")
                .font(.footnote).foregroundStyle(.secondary)
            }
        }.onDisappear { enrollment.cancel() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Speak. Shape. Send.").font(.title2.weight(.semibold))
                        Text("Dictate straight into the focused field. Turn Magic on to speak an instruction, then turn it off to edit the text in place.")
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
                    Text("Magic uses this model when you ask it to rewrite text in the focused field.")
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
    private var dictationSend: some View {
        @Bindable var settings = controller.settings
        return card {
            VStack(alignment: .leading, spacing: 14) {
                Label("Send dictation", systemImage: "text.cursor").font(.headline)
                Picker("Send dictation", selection: $settings.dictationSend) {
                    Text("Live").tag(DictationSendSetting.Mode.live)
                    Text("On stop").tag(DictationSendSetting.Mode.onStop)
                    Text("After a pause").tag(DictationSendSetting.Mode.afterPause)
                    Text("Line by line").tag(DictationSendSetting.Mode.lineByLine)
                }.labelsHidden().pickerStyle(.segmented)
                if settings.dictationSend == .afterPause {
                    Stepper(value: Binding(get: { DictationSendSetting.clampedPause(settings.dictationPause) },
                                           set: { settings.dictationPause = DictationSendSetting.clampedPause($0) }),
                            in: DictationSendSetting.pauseRange, step: DictationSendSetting.pauseStep) {
                        Text("Pause before sending: \(Int(DictationSendSetting.clampedPause(settings.dictationPause))) s")
                    }
                }
                Picker("Where words appear", selection: $panelMode) {
                    Text("Type into the field as I speak (panel only when needed)").tag(PanelDictationSetting.Mode.whenNeeded.rawValue)
                    Text("Always dictate in the panel, insert when done").tag(PanelDictationSetting.Mode.always.rawValue)
                }.pickerStyle(.radioGroup)
                Toggle("Typewriter for paste-only editors", isOn: $settings.typewriter)
                Toggle("Restore clipboard after a paste", isOn: $settings.restoreClipboard)
                Text("Live puts words into your field as you speak and revises them after cleanup. On stop waits for the whole take. After a pause also sends when you stop speaking; line by line sends finished sentences. In the panel, the take grows in the notch and goes into the field once it is final.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 20) {
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Magic shortcut", systemImage: "command").font(.headline)
                    HotkeyRecorderView(target: .magic)
                    Text("Speak an instruction about selected text, what you dictated, or the surrounding paragraph. Tap to latch Magic on and off, or hold to speak an instruction. Turning Magic off runs it. The previous composer shortcut is preserved.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Dictation shortcut", systemImage: "mic").font(.headline)
                    HotkeyRecorderView(target: .dictation)
                    Text("Types what you say straight into the focused field. Tap to start and stop, or hold to talk. While dictating, Magic temporarily routes speech into an instruction; ordinary dictation resumes when Magic turns off.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            dictationSend
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
