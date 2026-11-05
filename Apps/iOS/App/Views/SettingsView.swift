import SwiftUI
import UIKit
import AVFAudio
import LegatoClaude
import LegatoAgent
import LegatoAppServices

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let controller: AppController
    @AppStorage("composer.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("composer.personalPrompt") private var personalPrompt = ""
    @AppStorage(DictationSendSetting.modeKey, store: AppGroup.defaults) private var dictationSend = DictationSendSetting.defaultMode.rawValue
    @AppStorage(DictationSendSetting.pauseKey, store: AppGroup.defaults) private var dictationPause = DictationSendSetting.defaultPause
    @AppStorage(InstructionSendSetting.modeKey) private var instructionSend = InstructionSendSetting.Mode.manual.rawValue
    @AppStorage(InstructionSendSetting.pauseKey) private var instructionPause = InstructionSendSetting.defaultPause
    @AppStorage("voiceIsolation.enabled") private var onlyMyVoice = false
    @State private var enrollment = VoiceEnrollmentController.shared
    @State private var keepMicrophoneActive = ComposerMicrophonePreference.keepActive()
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

            Toggle("Only my voice (experimental)", isOn: $onlyMyVoice)
                .disabled(!enrollment.hasProfile || enrollment.isBusy)
                .accessibilityIdentifier("settings.onlyMyVoice")
            Text(enrollment.hasProfile ? "Voice profile saved on this device." : "Record your voice once to enable this filter.")
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
                    enrollment.record(microphoneBusy: { controller.composer.isArmed || controller.composer.holdsWarmInput || controller.composer.isListening || controller.composer.status == "starting" })
                }.accessibilityIdentifier("settings.recordVoiceProfile")
                if enrollment.hasProfile {
                    Button("Delete voice profile", role: .destructive) { enrollment.deleteProfile(); onlyMyVoice = false }
                        .accessibilityIdentifier("settings.deleteVoiceProfile")
                }
            }
            if let message = enrollment.message {
                Text(message).font(.callout).accessibilityIdentifier("settings.voiceEnrollmentMessage")
            }
            Text("First setup downloads a voice model. Only your voice profile is saved locally; this recording is not kept. Changes apply to the next take. Identification can delay the first words and may miss some of your speech. Overlapping voices may still get through. Meetings keep every speaker.")
                .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Voice isolation") }
            Section {
                Picker("Writing model", selection: $liveModel) {
                    ForEach(ModelChoice.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                NavigationLink {
                    PersonalInstructionsView(text: $personalPrompt)
                } label: {
                    LabeledContent("Personal instructions", value: personalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Optional" : "Added")
                }.accessibilityIdentifier("settings.personalInstructionsLink")
            } header: { Text("Writing") } footer: {
                Text("One model handles corrections and composes at pauses. Changes apply to your next session.")
            }
            Section {
                Picker("Send dictation", selection: $dictationSend) {
                    Text("On stop").tag(DictationSendSetting.Mode.onStop.rawValue)
                    Text("After a pause").tag(DictationSendSetting.Mode.afterPause.rawValue)
                    Text("Line by line").tag(DictationSendSetting.Mode.lineByLine.rawValue)
                }.accessibilityIdentifier("settings.dictationSend")
                if dictationSend == DictationSendSetting.Mode.afterPause.rawValue {
                    Stepper(value: Binding(get: { DictationSendSetting.clampedPause(dictationPause) },
                                           set: { dictationPause = DictationSendSetting.clampedPause($0) }),
                            in: DictationSendSetting.pauseRange, step: DictationSendSetting.pauseStep) {
                        LabeledContent("Pause before sending", value: "\(Int(DictationSendSetting.clampedPause(dictationPause))) s")
                    }.accessibilityIdentifier("settings.dictationPause")
                }
            } header: { Text("Dictation") } footer: {
                Text("On stop holds the whole take and types it once, cleaned as one text, when you stop. After a pause also types when you stop speaking for the pause. Line by line cleans and types each sentence as you speak.")
            }
            Section {
                Picker("Send instructions", selection: $instructionSend) {
                    Text("Manual").tag(InstructionSendSetting.Mode.manual.rawValue)
                    Text("Automatically after a pause").tag(InstructionSendSetting.Mode.automatic.rawValue)
                }.accessibilityIdentifier("settings.instructionSend")
                if instructionSend == InstructionSendSetting.Mode.automatic.rawValue {
                    Stepper(value: Binding(get: { InstructionSendSetting.clampedPause(instructionPause) },
                                           set: { instructionPause = InstructionSendSetting.clampedPause($0) }),
                            in: InstructionSendSetting.pauseRange, step: InstructionSendSetting.pauseStep) {
                        LabeledContent("Pause before sending", value: String(format: "%.1f s", InstructionSendSetting.clampedPause(instructionPause)))
                    }.accessibilityIdentifier("settings.instructionPause")
                }
            } header: { Text("Instructions") } footer: {
                Text("Speech builds one instruction until you tap Send in the strip. Automatic sends it after the pause; speaking again restarts the wait.")
            }
            Section {
                ProviderKeyRow(name: "Claude", service: "de.gruenwald.legato.claude")
                ProviderKeyRow(name: "Soniox", service: "de.gruenwald.legato.soniox")
            } header: { Text("Connections") } footer: {
                Text("Claude shapes your writing. Soniox transcribes your voice. Keys are stored securely on this device.")
            }
            Section {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Key sounds", isOn: $clicks)
                Button { openSettings() } label: { Label("Set up keyboard", systemImage: "keyboard") }
            } header: { Text("Keyboard") } footer: {
                Text("In iOS Settings, open Keyboards, enable Legato and Allow Full Access. Then touch and hold the globe key in any text field to choose Legato. Haptics and sounds require Full Access.")
            }
            Section {
                Toggle("Keep microphone active in background", isOn: $keepMicrophoneActive)
                    .accessibilityIdentifier("settings.keepMicrophoneActive")
            } header: { Text("Background microphone") } footer: {
                Text("Keeps a microphone session you enable available while using the keyboard or other apps. When off, switching away from Legato stops voice input. This switch never starts the microphone. Stop, clear and mute still control voice input.")
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
            } header: { Text("Setup") } footer: { Text("Microphone access is needed to compose by voice. You can change permissions in iOS Settings.") }
        }
        .navigationTitle("Settings")
        .onDisappear { enrollment.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { enrollment.cancel() } }
        .onChange(of: keepMicrophoneActive) { _, value in
            ComposerMicrophonePreference.setKeepActive(value)
            Task { await controller.composer.setKeepMicrophoneActive(value) }
        }
        .onChange(of: haptics) { _, value in Settings.keyboardHaptics = value }
        .onChange(of: clicks) { _, value in Settings.keyboardClicks = value }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
        }
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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
