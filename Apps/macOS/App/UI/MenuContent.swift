import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(controller.notice, systemImage: "waveform").font(.headline)
            Button(controller.isDictating ? "Stop composer" : "Voice composer") { controller.toggle() }
            Text(controller.settings.hotkey?.displayName ?? "Set a hotkey in Settings").foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Settings…") { NSApp.activate(); openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }.padding(16).frame(width: 300)
    }
}
