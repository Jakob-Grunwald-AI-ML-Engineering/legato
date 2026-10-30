import LegatoMac
import SwiftUI

/// Shows the current hotkey and records a new one: a lone modifier (Right ⌘) or a combination.
struct HotkeyRecorderView: View {
    @Environment(MacAppController.self) private var controller

    private var spec: HotkeySpec? { controller.settings.hotkey }
    private var isRecording: Bool { controller.isRecordingHotkey }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            recorder
            if !isRecording, let warning = spec?.warning {
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recorder: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.body, design: .rounded, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 140)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if isRecording {
                Button("Cancel") { controller.cancelRecording() }
            } else {
                Button(spec == nil ? "Record" : "Change") { controller.beginRecording() }

            }
        }
    }

    private var label: String {
        if isRecording { return controller.recordingPreview ?? "Press a key…" }
        return spec?.displayName ?? "Not set"
    }
}
