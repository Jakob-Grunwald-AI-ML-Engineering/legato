import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openSettings) private var openSettings
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
            Label(controller.settings.hotkey?.displayName ?? "Set a shortcut in Settings", systemImage: "command")
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
