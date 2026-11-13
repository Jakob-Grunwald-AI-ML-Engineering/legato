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
            Button(controller.dictation.speechMode == .instruction ? "Run Magic instruction" : "Speak a Magic instruction") { controller.toggleMagic() }
                .menuAction("menu.magic") { controller.toggleMagic() }
                .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
            Button(controller.dictation.isActive ? "Stop dictation" : "Dictate into the focused field") { controller.toggleDictation() }
                .menuAction("menu.dictation") { controller.toggleDictation() }
                .controlSize(.large)
            HStack(spacing: 8) {
                Button(controller.meetings.phase == .recording ? "Stop meeting" : "Start meeting") { controller.toggleMeeting() }
                    .controlSize(.large)
                    .menuAction("menu.meeting") { controller.toggleMeeting() }
                    .disabled(controller.meetings.phase == .starting || controller.meetings.phase == .stopping)
                Button("Meetings…") { NSApp.activate(); openWindow(id: MeetingController.windowID) }
                    .controlSize(.large)
                    .menuAction("menu.meetings") { NSApp.activate(); openWindow(id: MeetingController.windowID) }
            }
            Label("Magic \(controller.settings.hotkey?.displayName ?? "not set")", systemImage: "command")
                .font(.caption).foregroundStyle(.secondary)
            Label("Dictation \(controller.settings.dictationHotkey?.displayName ?? "not set")", systemImage: "mic")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Captured edits…") { NSApp.activate(); openWindow(id: "corrections") }
                .menuAction("menu.corrections") { NSApp.activate(); openWindow(id: "corrections") }
            HistoryList(entries: controller.recent, onCopy: { controller.copy($0) }, onDelete: { controller.delete($0) }, onCopyOriginal: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
            Divider()
            HStack {
                Button("Settings…") { NSApp.activate(); openSettings() }
                    .menuAction("menu.settings") { NSApp.activate(); openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                    .menuAction("menu.quit") { NSApplication.shared.terminate(nil) }
            }
        }.padding(20).frame(width: 300)
            // Reloads on open and whenever the composer or backfill stores a new revision.
            .task(id: controller.dictation.instruction.historyRevision + controller.dictation.pipeline.historyRevision) { await controller.refreshRecent() }
    }
}

private extension View {
    /// A button of the menu-bar window that assistive tools can find and press: an identifier, and the press (AXPress)
    /// runs the action directly, as the click does, instead of relying on the window being key.
    func menuAction(_ id: String, _ action: @escaping () -> Void) -> some View {
        accessibilityIdentifier(id).accessibilityAction(.default, action)
    }
}
