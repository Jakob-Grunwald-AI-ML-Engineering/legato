import LegatoMac
import SwiftUI

/// Shows and records the shortcut for one action.
struct HotkeyRecorderView: View {
    @Environment(MacAppController.self) private var controller
    var target = MacAppController.HotkeyTarget.magic

    private var spec: HotkeySpec? { controller.binding(for: target) }
    private var isRecording: Bool { controller.recordingTarget == target }

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
            if !isRecording, let warning = recordingWarning {
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordingWarning: HotkeySpec.Warning? {
        // Composer chords are consumed while available. Speech shortcuts are observed globally.
        if case .composer = target { return nil }
        return spec?.warning
    }

    private var recorder: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.body, design: .rounded, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minWidth: 160)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Current \(target.title) shortcut: \(label)")
            if isRecording {
                Button("Cancel") { controller.cancelRecording() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel recording \(target.title) shortcut")
            } else {
                Button(spec == nil ? "Record shortcut" : "Change shortcut") { controller.beginRecording(target) }
                    .disabled(!controller.permissions.hotkeyTapActive)
                    .accessibilityLabel("Record \(target.title) shortcut")
                Menu {
                    Button("Clear shortcut") { controller.clearBinding(for: target) }.disabled(spec == nil)
                    Button("Restore default") { controller.restoreDefault(for: target) }
                        .disabled(spec == target.defaultBinding)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("\(target.title) shortcut options")
                .help("Clear or restore this shortcut")
            }
        }
    }

    private var label: String {
        if isRecording { return controller.recordingPreview ?? "Press a key…" }
        return spec?.displayName ?? "Not set"
    }
}
