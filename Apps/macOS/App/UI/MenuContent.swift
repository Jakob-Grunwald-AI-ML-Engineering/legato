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
            HistoryList(
                entries: controller.recent,
                onCopy: { controller.copy($0) },
                onDelete: { controller.delete($0) })
            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 340)
        .task { await controller.refreshRecent() }
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
