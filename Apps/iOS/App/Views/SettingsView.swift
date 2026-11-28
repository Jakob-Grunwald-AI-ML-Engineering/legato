import SwiftUI
import UIKit
import AVFAudio
import LegatoClaude
import LegatoAgent
import LegatoAppServices
import LegatoKeyboardCore

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let controller: AppController
    @AppStorage("microphone.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("microphone.personalPrompt") private var personalPrompt = ""
    @AppStorage(DictationSendSetting.modeKey, store: AppGroup.defaults) private var dictationSend = DictationSendSetting.defaultMode.rawValue
    @AppStorage(DictationSendSetting.liveSendKey, store: AppGroup.defaults) private var liveSend = DictationSendSetting.defaultLiveSend.rawValue
    @AppStorage(DictationSendSetting.pauseKey, store: AppGroup.defaults) private var dictationPause = DictationSendSetting.defaultPause
    @AppStorage(DictationSendSetting.cleanupModelKey, store: AppGroup.defaults) private var cleanupModel = DictationSendSetting.defaultCleanupModel.settingValue
    @AppStorage("voiceIsolation.enabled") private var onlyMyVoice = false
    @State private var enrollment = VoiceEnrollmentController.shared
    @State private var keepMicrophoneActive = ComposerMicrophonePreference.keepActive()
    @State private var combineMicrophoneInputs = ComposerMicrophonePreference.combineInputs()
    @AppStorage(ShortcutActionSetting.key, store: AppGroup.defaults) private var shortcutAction = ShortcutActionSetting.Action.meeting.rawValue
    @AppStorage(DictationKeySide.preferenceKey, store: AppGroup.defaults) private var dictationKeySide = DictationKeySide.standard
    @State private var haptics = Settings.keyboardHaptics
    @State private var clicks = Settings.keyboardClicks
    @State private var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted

    var body: some View {
        Form {
            Section {
                Label("Your voice, your words.", systemImage: "waveform.circle.fill")
                    .font(.headline).foregroundStyle(.indigo).padding(.vertical, 4)
            }
            Section {
                NavigationLink {
                    BackgroundVoicesView(enrollment: enrollment, microphoneBusy: microphoneBusy)
                } label: {
                    LabeledContent("Background voices", value: onlyMyVoice ? "On" : enrollment.hasProfile ? "Off" : "Not set up")
                }.accessibilityIdentifier("settings.backgroundVoicesLink")
            } footer: { Text("Quietly reduces other people’s voices and the TV in your dictation. Experimental.") }
            Section {
                Picker("Instruction model", selection: $liveModel) {
                    ForEach(ModelChoice.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                NavigationLink {
                    PersonalInstructionsView(text: $personalPrompt)
                } label: {
                    LabeledContent("Personal instructions", value: personalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Optional" : "Added")
                }.accessibilityIdentifier("settings.personalInstructionsLink")
            } header: { Text("Instructions") } footer: {
                Text("The model that follows your spoken instructions: the magic key on the keyboard. Dictation cleanup has its own model below. Changes apply to your next session.")
            }
            Section {
                Picker("Send dictation", selection: $dictationSend) {
                    Text("As you speak").tag(DictationSendSetting.Mode.live.rawValue)
                    Text("On stop").tag(DictationSendSetting.Mode.onStop.rawValue)
                    Text("After a pause").tag(DictationSendSetting.Mode.afterPause.rawValue)
                }.accessibilityIdentifier("settings.dictationSend")
                if dictationSend == DictationSendSetting.Mode.afterPause.rawValue {
                    Stepper(value: Binding(get: { DictationSendSetting.clampedPause(dictationPause) },
                                           set: { dictationPause = DictationSendSetting.clampedPause($0) }),
                            in: DictationSendSetting.pauseRange, step: DictationSendSetting.pauseStep) {
                        LabeledContent("Pause before sending", value: "\(Int(DictationSendSetting.clampedPause(dictationPause))) s")
                    }.accessibilityIdentifier("settings.dictationPause")
                }
                if dictationSend == DictationSendSetting.Mode.live.rawValue {
                    Picker("Send to field", selection: $liveSend) {
                        Text("When I tap the preview").tag(DictationSendSetting.LiveSend.manual.rawValue)
                        Text("At each sentence end").tag(DictationSendSetting.LiveSend.sentence.rawValue)
                    }.accessibilityIdentifier("settings.liveSend")
                    Picker("Dictation cleanup model", selection: $cleanupModel) {
                        ForEach(ModelChoice.cleanupChoices, id: \.settingValue) { Text($0.label).tag($0.settingValue) }
                    }.accessibilityIdentifier("settings.dictationCleanupModel")
                }
            } header: { Text("Dictation") } footer: {
                Text("As you speak keeps your words in the preview above the keys; tapping it (or Stop) sends them to the field, cleaned, or each finished sentence is sent automatically. On stop holds the whole take and types it once, cleaned as one text, when you stop. After a pause also types when you stop speaking for the pause. Haiku is quicker, Sonnet more careful.")
            }
            Section {
                ProviderKeyRow(name: "Claude", service: "de.gruenwald.legato.claude")
                ProviderKeyRow(name: "Soniox", service: "de.gruenwald.legato.soniox")
            } header: { Text("Connections") } footer: {
                Text("Claude shapes your writing. Soniox transcribes your voice. Keys are stored securely on this device.")
            }
            Section {
                Picker("Action Button and Control", selection: $shortcutAction) {
                    Text("Meeting").tag(ShortcutActionSetting.Action.meeting.rawValue)
                    Text("Dictation").tag(ShortcutActionSetting.Action.dictation.rawValue)
                }.accessibilityIdentifier("settings.shortcutAction")
            } footer: {
                Text("To assign the Action Button, open iOS Settings → Action Button → Shortcut and choose Legato’s Toggle recording shortcut. Meeting starts or stops a recording. Dictation starts a take when the keyboard is open and readies the microphone when it’s closed.")
            }
            Section {
                NavigationLink("Practice keyboard") { KeyboardPracticeView() }
                Picker("Dictation key", selection: $dictationKeySide) {
                    Text("Left").tag(DictationKeySide.left)
                    Text("Right").tag(DictationKeySide.right)
                }
                .accessibilityIdentifier("settings.dictationKeySide")
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Key sounds", isOn: $clicks)
                Button { openSettings() } label: { Label("Set up keyboard", systemImage: "keyboard") }
            } header: { Text("Keyboard") } footer: {
                Text("In iOS Settings, open Keyboards, enable Legato and Allow Full Access. Then touch and hold the globe key in any text field to choose Legato. The dictation key sits beside the transcript: tap to dictate or pause, swipe down to shrink the keyboard and up to bring it back, swipe left to undo and right to redo. Haptics, sounds and the dictation key's side require Full Access.")
            }
            Section {
                Toggle("Keep microphone active in background", isOn: $keepMicrophoneActive)
                    .accessibilityIdentifier("settings.keepMicrophoneActive")
            } header: { Text("Background microphone") } footer: {
                Text("Keeps a microphone session you enable available while using the keyboard or other apps. When off, switching away from Legato stops voice input. This switch never starts the microphone. Release microphone ends the hold.")
            }
            Section {
                Toggle("Combine phone and headset microphones", isOn: $combineMicrophoneInputs)
                    .accessibilityIdentifier("settings.combineMicrophoneInputs")
                if controller.microphone.isArmed {
                    Button("Release microphone") { Task { await controller.releaseMicrophone() } }
                        .accessibilityIdentifier("settings.releaseMicrophone")
                }
            } header: { Text("Microphone inputs") } footer: {
                Text("Combines compatible headset and phone microphones on iOS 26.2 or later. Other apps’ music may pause while both are held. Turn off to use the phone microphone and allow music to continue. Changes apply after releasing and readying the microphone again.")
            }
            Section {
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    Text(microphoneAllowed ? "Allowed" : "Needs access").foregroundStyle(.secondary)
                }
                Button(microphoneAllowed ? "Open iOS settings" : "Allow microphone access") {
                    if AVAudioApplication.shared.recordPermission == .undetermined {
                        AVAudioApplication.requestRecordPermission { allowed in Task { @MainActor in microphoneAllowed = allowed } }
                    } else { openSettings() }
                }
            } header: { Text("Setup") } footer: { Text("Microphone access is needed to dictate. You can change permissions in iOS Settings.") }
        }
        .navigationTitle("Settings")
        .onAppear { dictationSend = DictationSendSetting.mode(in: AppGroup.defaults).rawValue; enrollment.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { enrollment.cancel() } }
        .onChange(of: keepMicrophoneActive) { _, value in
            ComposerMicrophonePreference.setKeepActive(value)
            Task { await controller.microphone.setKeepMicrophoneActive(value) }
        }
        .onChange(of: combineMicrophoneInputs) { _, value in ComposerMicrophonePreference.setCombineInputs(value) }
        .onChange(of: haptics) { _, value in Settings.keyboardHaptics = value }
        .onChange(of: clicks) { _, value in Settings.keyboardClicks = value }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
        }
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    private func microphoneBusy() -> Bool {
        controller.meetings.isActive || controller.microphone.isArmed || controller.microphone.holdsWarmInput
            || controller.microphone.isListening || controller.microphone.status == "starting"
    }
}

/// Settings → Background voices: the option, the guided voice setup, recorded settings and kept test recordings.
private struct BackgroundVoicesView: View {
    @Environment(\.scenePhase) private var scenePhase
    let enrollment: VoiceEnrollmentController
    let microphoneBusy: @MainActor () -> Bool
    @AppStorage("voiceIsolation.enabled") private var onlyMyVoice = false
    @State private var addingSetting = false
    @State private var newSettingName = ""
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var enrollment = enrollment
        Form {
            Section {
                Toggle(VoiceSetupCopy.toggle, isOn: $onlyMyVoice)
                    .disabled(!enrollment.hasProfile || enrollment.isBusy)
                    .accessibilityIdentifier("settings.onlyMyVoice")
                Text(enrollment.hasProfile ? VoiceSetupCopy.saved : VoiceSetupCopy.notSetUp)
                    .font(.callout).foregroundStyle(.secondary)
                if !enrollment.hasProfile {
                    Button(VoiceSetupCopy.setupButton) { enrollment.startFirstSetup(microphoneBusy: microphoneBusy) }
                        .disabled(enrollment.isBusy).accessibilityIdentifier("settings.setUpVoice")
                }
                if let message = enrollment.message {
                    Text(message).font(.callout).accessibilityIdentifier("settings.voiceEnrollmentMessage")
                }
            } footer: { Text(VoiceSetupCopy.about) }
            if enrollment.hasProfile {
                Section {
                    ForEach(enrollment.situations) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(VoiceSetupCopy.recordButton(row)) { enrollment.record(situationID: row.id, microphoneBusy: microphoneBusy) }
                                .buttonStyle(.borderless).disabled(enrollment.isBusy)
                                .accessibilityIdentifier("settings.recordSetting.\(row.id)")
                        }
                        .deleteDisabled(!row.isCustom)
                    }
                    .onDelete { offsets in
                        for index in offsets where enrollment.situations[index].isCustom { enrollment.deleteSituation(id: enrollment.situations[index].id) }
                    }
                    Button(VoiceSetupCopy.addSetting) { newSettingName = ""; addingSetting = true }
                        .disabled(enrollment.isBusy).accessibilityIdentifier("settings.addSetting")
                } header: { Text(VoiceSetupCopy.settingsHeader) } footer: { Text(VoiceSetupCopy.settingsAbout) }
            }
            Section {
                Toggle(VoiceSetupCopy.keepRecordings, isOn: $enrollment.keepRecordings)
                    .accessibilityIdentifier("settings.keepVoiceRecordings")
                if !enrollment.recordings.isEmpty {
                    NavigationLink {
                        VoiceRecordingsView(enrollment: enrollment)
                    } label: {
                        LabeledContent("Recordings", value: "\(enrollment.recordings.count)")
                    }.accessibilityIdentifier("settings.voiceRecordingsLink")
                }
            } footer: { Text(VoiceSetupCopy.recordingsAbout) }
            if enrollment.hasProfile || !enrollment.recordings.isEmpty {
                Section {
                    Button(VoiceSetupCopy.deleteVoice, role: .destructive) { confirmingDelete = true }
                        .disabled(enrollment.isBusy).accessibilityIdentifier("settings.deleteVoice")
                } footer: { Text(VoiceSetupCopy.deleteVoiceAbout) }
            }
        }
        .navigationTitle("Background voices").navigationBarTitleDisplayMode(.inline)
        .onAppear { enrollment.refresh() }
        .onDisappear { enrollment.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { enrollment.cancel() } }
        .sheet(isPresented: Binding(get: { enrollment.guide != nil }, set: { if !$0 { enrollment.cancel() } })) {
            VoiceRecordingGuideView(controller: enrollment).interactiveDismissDisabled()
        }
        .alert(VoiceSetupCopy.addSettingTitle, isPresented: $addingSetting) {
            TextField(VoiceSetupCopy.addSettingPlaceholder, text: $newSettingName)
            Button("Add") { enrollment.addSituation(named: newSettingName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(VoiceSetupCopy.deleteVoice, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(VoiceSetupCopy.deleteVoice, role: .destructive) { enrollment.deleteProfile(); onlyMyVoice = false }
        } message: { Text(VoiceSetupCopy.deleteVoiceAbout) }
    }
}

/// Kept voice recordings, each exportable on its own or all together (AirDrop to a Mac for the replay tool).
private struct VoiceRecordingsView: View {
    let enrollment: VoiceEnrollmentController
    var body: some View {
        List {
            Section {
                ShareLink(item: enrollment.exportAll(), preview: SharePreview(VoiceSetupCopy.exportAll)) {
                    Label(VoiceSetupCopy.exportAll, systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("settings.exportVoiceRecordings")
            }
            Section {
                ForEach(enrollment.recordings) { entry in
                    ShareLink(item: enrollment.export(entry), preview: SharePreview(VoiceSetupCopy.recordingTitle(entry))) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(VoiceSetupCopy.recordingTitle(entry)).foregroundStyle(.primary)
                            Text(VoiceSetupCopy.recordingDetail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: { Text("Tap a recording to share it with its sentences.") }
        }
        .navigationTitle("Recordings").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PersonalInstructionsView: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        Form {
            Section {
                TextField("For example: Use British spelling and keep my tone conversational.", text: $text, axis: .vertical)
                    .lineLimit(8...20).focused($focused)
                    .accessibilityIdentifier("settings.personalInstructions")
            } footer: { Text("Tell Legato about your tone, spelling or formatting preferences. Saved automatically for your next session.") }
        }
        .navigationTitle("Personal instructions").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
    }
}

private struct ProviderKeyRow: View {
    let name: String
    let service: String
    @State private var configured = false
    var body: some View {
        NavigationLink {
            ProviderKeyEditor(name: name, service: service, configured: $configured)
        } label: {
            HStack {
                Text(name)
                Spacer()
                Label(configured ? "Key saved" : "Add key", systemImage: configured ? "checkmark.shield.fill" : "plus.circle")
                    .font(.subheadline).foregroundStyle(configured ? Color.secondary : .indigo)
            }
        }
        .task { configured = ((try? KeychainKeyStore(service: service).apiKey()) ?? "").isEmpty == false }
    }
}

private struct ProviderKeyEditor: View {
    let name: String
    let service: String
    @Binding var configured: Bool
    @State private var replacement = ""
    @State private var message: String?
    @FocusState private var focused: Bool
    private var trimmedKey: String { replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Form {
            Section {
                Label(configured ? "A key is saved on this device" : "No key saved yet", systemImage: configured ? "checkmark.shield.fill" : "key")
                    .foregroundStyle(configured ? Color.secondary : .indigo)
                SecureField(configured ? "Paste replacement key" : "Paste API key", text: $replacement)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                    .accessibilityIdentifier("settings.\(name.lowercased())Key")
                Button(configured ? "Replace \(name) key" : "Save \(name) key") {
                    guard !trimmedKey.isEmpty else { return }
                    do {
                        try KeychainKeyStore(service: service).save(apiKey: trimmedKey)
                        configured = true; replacement = ""; focused = false; message = "\(name) key saved."
                    } catch { message = "Could not save the key. Please try again." }
                }
                .disabled(trimmedKey.isEmpty)
                if let message { Text(message).font(.footnote).accessibilityIdentifier("settings.keyMessage") }
            } footer: { Text("Your saved key is never displayed. Leave this field empty to keep it. Saving changes only your \(name) key.") }
        }
        .navigationTitle("\(name) API key").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
        .onDisappear { replacement = "" }
    }
}

private extension ModelChoice {
    var label: String { switch self { case .haiku: "Haiku 5.5"; case .sonnet: "Sonnet 5.5"; case .opus: "Opus 5.5" } }
}
