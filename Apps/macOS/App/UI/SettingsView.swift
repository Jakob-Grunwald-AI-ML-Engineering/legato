import SwiftUI
import LegatoClaude
import LegatoAgent

struct SettingsView: View {
    @Environment(MacAppController.self) private var controller
    @AppStorage("composer.liveModel") private var liveModel = ModelChoice.haiku.rawValue
    @AppStorage("composer.personalPrompt") private var personalPrompt = ""
    @State private var claudeKey = ""
    @State private var sonioxKey = ""
    @State private var keyNotice = ""
    var body: some View {
        Form {
            Section("API keys") {
                SecureField("Claude API key", text: $claudeKey)
                SecureField("Soniox API key", text: $sonioxKey)
                Button("Save keys in Keychain") { saveKeys() }
                Text(keyNotice).font(.caption).foregroundStyle(.secondary)
            }
            Section("Composer") {
                modelPicker("Writing model", selection: $liveModel)
                Text("One model handles quick corrections and paused/final composing.").font(.caption).foregroundStyle(.secondary)
                Text("Personal prompt")
                TextEditor(text: $personalPrompt).frame(height: 80)
            }
            Section("Hotkey") { HotkeyRecorderView() }
            Section("Permissions") {
                Button(controller.permissions.accessibility ? "Accessibility granted" : "Grant Accessibility") { controller.permissions.requestAccessibility() }
                Button(controller.permissions.micGranted ? "Microphone granted" : "Grant Microphone") { Task { await controller.permissions.requestMicrophone() } }
                if controller.permissions.needsInputMonitoring { Button("Grant Input Monitoring") { controller.permissions.requestInputMonitoring() } }
            }
        }.padding().frame(width: 460)
        .task {
            do {
                let claude = try KeychainKeyStore().apiKey()?.isEmpty == false
                let soniox = try KeychainKeyStore(service: "de.gruenwald.legato.soniox").apiKey()?.isEmpty == false
                keyNotice = "Claude: \(claude ? "saved" : "missing") · Soniox: \(soniox ? "saved" : "missing"). Blank fields keep saved keys."
            } catch { keyNotice = "Could not read Keychain: \(error.localizedDescription)" }
        }
    }
    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModelChoice.allCases, id: \.rawValue) { model in Text(model.rawValue).tag(model.rawValue) }
        }
    }
    private func saveKeys() {
        do {
            if !claudeKey.isEmpty { try KeychainKeyStore().save(apiKey: claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if !sonioxKey.isEmpty { try KeychainKeyStore(service: "de.gruenwald.legato.soniox").save(apiKey: sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
            claudeKey = ""; sonioxKey = ""; keyNotice = "Keys saved on this Mac."
        } catch { keyNotice = "Could not save keys: \(error.localizedDescription)" }
    }
}
