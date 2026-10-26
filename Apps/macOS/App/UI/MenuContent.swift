import AppKit
import LegatoModels
import SwiftUI

/// The menu-bar window: status, the last 20 dictations, Settings, Quit.
struct MenuContent: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            if controller.needsSetup {
                Button("Finish setup…") { controller.requestOnboarding() }
            }
            Divider()
            meetingSection
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

    /// Start and stop a meeting, mute the mic, open the Meetings window.
    private var meetingSection: some View {
        let meetings = controller.meetings
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(meetings.phase == .recording ? "Stop meeting" : "Start meeting") {
                    Task { await meetings.toggle() }
                }
                .disabled(meetings.phase == .starting || meetings.phase == .stopping)
                if meetings.phase == .recording {
                    Text(Self.clock(meetings.elapsed)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Meetings…") {
                    NSApp.activate()
                    openWindow(id: MeetingController.windowID)
                }
            }
            if meetings.phase == .recording {
                Toggle("Mute my mic", isOn: Binding(
                    get: { meetings.manualMute }, set: { _ in meetings.toggleManualMute() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if meetings.autoMute {
                    Text("Muted automatically: the call app closed its mic.").font(.caption).foregroundStyle(.secondary)
                }
                if let warning = meetings.systemAudioWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notice = meetings.notice, meetings.phase == .idle {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
                    ForEach(controller.models.streamingFamilies) { family in
                        let label = controller.models.liveLabel(of: family)
                        if let chosen = controller.models.chosenModel(of: family),
                            controller.installedStreamingModels.contains(chosen.id)
                        {
                            Toggle(label, isOn: Binding(
                                get: { controller.engineStatus.modelID.map(family.contains) ?? false },
                                set: { if $0 { controller.switchEngine(to: family) } }))
                        } else {
                            Button("\(label) (not installed)…") { open(.speech) }
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
