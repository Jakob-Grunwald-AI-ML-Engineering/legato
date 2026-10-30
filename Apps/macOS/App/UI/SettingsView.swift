import SwiftUI

struct SettingsView: View {
    @Environment(MacAppController.self) private var controller
    var body: some View {
        Form {
            Section("Composer") { Text("Composer coming").foregroundStyle(.secondary) }
            Section("Hotkey") { HotkeyRecorderView() }
            Section("Permissions") {
                Button(controller.permissions.accessibility ? "Accessibility granted" : "Grant Accessibility") { controller.permissions.requestAccessibility() }
                Button(controller.permissions.micGranted ? "Microphone granted" : "Grant Microphone") { Task { await controller.permissions.requestMicrophone() } }
                if controller.permissions.needsInputMonitoring { Button("Grant Input Monitoring") { controller.permissions.requestInputMonitoring() } }
            }
        }.padding().frame(width: 460)
    }
}
