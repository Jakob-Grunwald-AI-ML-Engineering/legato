import SwiftUI
import UIKit
import LegatoClaude
import LegatoAgent

struct SettingsView: View {
    let controller: AppController
    @State private var claudeKey = ""
    @State private var sonioxKey = ""
    @State private var keyMessage: String?
    @AppStorage("composer.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("composer.personalPrompt") private var personalPrompt = ""
    var body: some View {
        Form {
            Section("API keys · stored on this device") {
                SecureField("Claude API key", text: $claudeKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Soniox API key", text: $sonioxKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save keys") {
                    do {
                        try KeychainKeyStore().save(apiKey: claudeKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        try KeychainKeyStore(service: "de.gruenwald.legato.soniox").save(apiKey: sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyMessage = "Keys saved"
                    } catch { keyMessage = error.localizedDescription }
                }
                if let keyMessage { Text(keyMessage).font(.caption) }
            }
            Section("Composer") {
                Picker("Writing model", selection: $liveModel) { ForEach(ModelChoice.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                Text("One model handles quick corrections and paused/final composing.").font(.caption).foregroundStyle(.secondary)
                TextField("Personal instructions", text: $personalPrompt, axis: .vertical).lineLimit(3...8)
            }
            Section("Keyboard") {
                Toggle("Haptics", isOn: Binding(get: { Settings.keyboardHaptics }, set: { Settings.keyboardHaptics = $0 }))
                Toggle("Key sounds", isOn: Binding(get: { Settings.keyboardClicks }, set: { Settings.keyboardClicks = $0 }))
                Button("Open keyboard settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
        }.navigationTitle("Settings").task {
            claudeKey = (try? KeychainKeyStore().apiKey()) ?? ""
            sonioxKey = (try? KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()) ?? ""
        }
    }
}
private extension ModelChoice {
    var label: String { switch self { case .haiku: "Haiku 5.5"; case .sonnet: "Sonnet 5.5"; case .opus: "Opus 5.5" } }
}
