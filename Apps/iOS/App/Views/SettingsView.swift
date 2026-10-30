import SwiftUI
import UIKit

struct SettingsView: View {
    let controller: AppController
    var body: some View {
        Form {
            Section("Composer") { Text("Composer coming").foregroundStyle(.secondary) }
            Section("Keyboard") {
                Toggle("Haptics", isOn: Binding(get: { Settings.keyboardHaptics }, set: { Settings.keyboardHaptics = $0 }))
                Toggle("Key sounds", isOn: Binding(get: { Settings.keyboardClicks }, set: { Settings.keyboardClicks = $0 }))
                Button("Open keyboard settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section("Vocabulary") { Text("Personal vocabulary is kept on this device.").foregroundStyle(.secondary) }
        }.navigationTitle("Settings")
    }
}
