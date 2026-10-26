import AppKit
import SwiftUI

/// The menu-bar window: status, the last 20 dictations, Settings, Quit.
struct MenuContent: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            if controller.needsSetup {
                Button("Finish setup…") { controller.requestOnboarding() }
            }
            Divider()
            quickSwitches
            Divider()
            HistoryList(
                entries: controller.recent,
                onCopy: { controller.copy($0) },
                onDelete: { controller.delete($0) })
            versions
            Divider()
            HStack {
                Button("Settings…") { open(.general) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 340)
        .task {
            await controller.refreshRecent()
            await controller.refreshInstalledModels()
        }
    }

    private func open(_ tab: MacAppController.SettingsTab) {
        controller.settingsTab = tab
        NSApp.activate()
        openSettings()
    }

    /// The engine and cleanup on/off, to flip while testing.
    private var quickSwitches: some View {
        @Bindable var settings = controller.settings
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Engine")
                Spacer()
                Menu(controller.engineStatus.name) {
                    Toggle("Apple Speech", isOn: Binding(
                        get: { controller.engineStatus.modelID == nil },
                        set: { if $0 { controller.switchEngine(to: nil) } }))
                    ForEach(controller.models.streamingModels) { descriptor in
                        if controller.installedStreamingModels.contains(descriptor.id) {
                            Toggle(descriptor.displayName, isOn: Binding(
                                get: { controller.engineStatus.modelID == descriptor.id },
                                set: { if $0 { controller.switchEngine(to: descriptor.id) } }))
                        } else {
                            Button("\(descriptor.displayName) (not installed)…") { open(.speech) }
                        }
                    }
                    Divider()
                    Button("Speech engine settings…") { open(.speech) }
                }
                .fixedSize()
            }
            Toggle("Clean up dictation", isOn: $settings.cleanupEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    /// Versions of the last dictation: back to the raw text, or a stronger rewrite.
    @ViewBuilder private var versions: some View {
        if let last = controller.lastDictation, !controller.isDictating {
            HStack {
                if last.rawText != nil {
                    Button("Revert last to raw") { controller.revertLastToRaw() }
                }
                Button(controller.isRefining ? "Refining…" : "Refine last") {
                    Task { await controller.refineLast() }
                }
                .disabled(controller.isRefining)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.statusSymbol)
                .foregroundStyle(controller.isDictating ? Color.red : Color.secondary)
            Text(controller.statusText)
                .font(.headline)
            Spacer()
        }
    }
}
