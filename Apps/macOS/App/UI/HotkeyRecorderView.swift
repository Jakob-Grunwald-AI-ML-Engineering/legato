import SwiftUI

/// Shows the current hotkey and records a new one: a lone modifier (Right ⌘) or a combination.
struct HotkeyRecorderView: View {
    @Environment(MacAppController.self) private var controller

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.body, design: .rounded, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 140)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if controller.isRecordingHotkey {
                Button("Cancel") { controller.cancelRecording() }
            } else {
                Button(controller.settings.hotkey == nil ? "Record" : "Change") { controller.beginRecording() }
            }
        }
    }

    private var label: String {
        if controller.isRecordingHotkey { return controller.recordingPreview ?? "Press a key…" }
        return controller.settings.hotkey?.displayName ?? "Not set"
    }
}
