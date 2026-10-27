import SwiftUI

/// First-run and repair flow: permissions, then the hotkey, then the speech model.
struct OnboardingView: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let permissions = controller.permissions
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Legato").font(.title.bold())
                Text("Dictate into any app. Speech is recognized on this Mac and never leaves it.")
                    .foregroundStyle(.secondary)
            }

            step(1, "Permissions", done: controller.permissionsDone) {
                row("Microphone", "To hear you.", granted: permissions.micGranted,
                    action: permissions.mic == .denied ? "Open Settings" : "Allow") {
                    Task { await permissions.requestMicrophone() }
                }
                row("Accessibility", "To type into other apps and to see the hotkey.", granted: permissions.accessibility,
                    action: "Grant…") { permissions.requestAccessibility() }
                if permissions.needsInputMonitoring {
                    row("Input Monitoring", "macOS also wants this before Legato can see the hotkey.",
                        granted: false, action: "Grant…") { permissions.requestInputMonitoring() }
                }
                if !permissions.accessibility {
                    Text("Turn Legato on in System Settings > Privacy & Security > Accessibility. This page updates by itself.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            step(2, "Hotkey", done: controller.settings.hotkey != nil, enabled: controller.permissionsDone) {
                Text("Press the key you want to dictate with: a single modifier such as Right ⌘, or a combination.")
                    .font(.callout).foregroundStyle(.secondary)
                HotkeyRecorderView()
            }

            step(3, "Speech model", done: permissions.modelInstalled) {
                if permissions.appleSpeechLive {
                    modelRow(permissions.model)
                } else {
                    Label("Using \(controller.engineStatus.name)", systemImage: "checkmark").foregroundStyle(.green)
                }
            }

            step(4, "Meetings (optional)", done: false) {
                row("System Audio Recording",
                    "To transcribe the other side of a meeting. macOS asks the first time you start one; there is no way to check it beforehand.",
                    granted: false, action: "Open Settings") { permissions.openSystemAudioRecordingSettings() }
                Text("If Them stays empty, enable Legato under System Audio Recording Only.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(controller.needsSetup ? "Finish later" : "Done") { dismissWindow(id: MacAppController.onboardingWindowID) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await permissions.refreshModel() }
    }

    // MARK: Pieces

    private func step<Content: View>(
        _ number: Int, _ title: String, done: Bool, enabled: Bool = true, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .font(.title3)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(.leading, 28)
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private func row(_ title: String, _ detail: String, granted: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark").foregroundStyle(.green)
            } else {
                Button(action, action: perform)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ state: Permissions.ModelState) -> some View {
        switch state {
        case .unknown:
            ProgressView().controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark").foregroundStyle(.green)
        case .missing:
            HStack {
                Text("The on-device model for \(Locale.current.identifier) is not installed yet.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Download") { controller.permissions.installModel() }
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack {
                Text(message).font(.callout).foregroundStyle(.red)
                Spacer()
                Button("Retry") { controller.permissions.installModel() }
            }
        }
    }
}
