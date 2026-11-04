import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.title).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Legato").font(.headline)
                    Text(controller.notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(controller.isDictating ? "Stop composer" : "Open voice composer") { controller.toggle() }
                .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
            Button(controller.dictation.isActive ? "Stop dictation" : "Dictate into the focused field") { controller.toggleDictation() }
                .controlSize(.large)
            HStack(spacing: 8) {
                Button(controller.meetings.phase == .recording ? "Stop meeting" : "Start meeting") { controller.toggleMeeting() }
                    .controlSize(.large)
                    .disabled(controller.meetings.phase == .starting || controller.meetings.phase == .stopping)
                Button("Meetings…") { NSApp.activate(); openWindow(id: MeetingController.windowID) }
                    .controlSize(.large)
            }
            Label("Composer \(controller.settings.hotkey?.displayName ?? "not set")", systemImage: "command")
                .font(.caption).foregroundStyle(.secondary)
            Label("Dictation \(controller.settings.dictationHotkey?.displayName ?? "not set")", systemImage: "mic")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HistoryList(entries: controller.recent, onCopy: { controller.copy($0) }, onDelete: { controller.delete($0) })
            Divider()
            HStack {
                Button("Settings…") { NSApp.activate(); openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }.padding(20).frame(width: 300)
            // Reloads on open and whenever the composer or backfill stores a new revision.
            .task(id: controller.composer.historyRevision) { await controller.refreshRecent() }
    }
}
