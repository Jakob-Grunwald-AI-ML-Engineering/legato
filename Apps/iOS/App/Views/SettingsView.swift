import SwiftUI
import UIKit
import AVFAudio
import LegatoClaude
import LegatoAgent

struct SettingsView: View {
    let controller: AppController
    @AppStorage("composer.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("composer.personalPrompt") private var personalPrompt = ""
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
