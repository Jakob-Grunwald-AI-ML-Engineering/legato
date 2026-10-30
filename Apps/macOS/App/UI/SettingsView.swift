import LegatoMac
import SwiftUI

/// The Settings window: General (hotkey, text, login), Speech engine, Cleanup and Meetings.
struct SettingsView: View {
    @Environment(MacAppController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        TabView(selection: $controller.settingsTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(MacAppController.SettingsTab.general)
            SpeechEngineSettingsView()
                .frame(width: 520, height: 560)
                .tabItem { Label("Speech engine", systemImage: "waveform") }
                .tag(MacAppController.SettingsTab.speech)
            CleanupSettingsView()
                .frame(width: 520, height: 620)
                .tabItem { Label("Cleanup", systemImage: "sparkles") }
                .tag(MacAppController.SettingsTab.cleanup)
            MeetingSettingsView()
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
                .tag(MacAppController.SettingsTab.meetings)
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(MacAppController.self) private var controller

    var body: some View {
        @Bindable var settings = controller.settings
        Form {
            Section("Hotkey") {
                LabeledContent("Trigger") { HotkeyRecorderView() }
                if !controller.permissions.hotkeyTapActive {
                    Text("The hotkey needs Accessibility access.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker("Gesture", selection: $settings.gestureMode) {
                    ForEach(HotkeyGesture.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Text") {
                Picker("Insertion", selection: $settings.insertionMode) {
                    ForEach(FieldWriter.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Restore the clipboard after pasting", isOn: $settings.restoreClipboard)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.loginItem.isEnabled },
                    set: { controller.loginItem.set($0) }))
                if let error = controller.loginItem.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Button("Run setup again…") { controller.requestOnboarding() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { controller.loginItem.refresh() }
    }
}
