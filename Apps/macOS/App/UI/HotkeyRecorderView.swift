import LegatoMac
import SwiftUI

/// Shows the current hotkey and records a new one: a lone modifier (Right ⌘) or a combination.
struct HotkeyRecorderView: View {
    @Environment(MacAppController.self) private var controller

    private var spec: HotkeySpec? { controller.settings.hotkey }
    private var isRecording: Bool { controller.isRecordingHotkey }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recorder
            if isRecording {
                Label("Listening for a shortcut…", systemImage: "record.circle")
                    .font(.callout).foregroundStyle(.tint)
            } else if !controller.permissions.hotkeyTapActive {
                Text("Shortcut recording is unavailable. Allow Accessibility and Input Monitoring, then reopen Legato if needed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
                .padding(.vertical, 10)
                .frame(minWidth: 160)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Current shortcut: \(label)")
            if isRecording {
                Button("Cancel") { controller.cancelRecording() }.keyboardShortcut(.cancelAction)
            } else {
                Button(spec == nil ? "Record shortcut" : "Change shortcut") { controller.beginRecording() }
                    .disabled(!controller.permissions.hotkeyTapActive)

            }
        }
    }

    private var label: String {
        if isRecording { return controller.recordingPreview ?? "Press a key…" }
        return spec?.displayName ?? "Not set"
    }
}
