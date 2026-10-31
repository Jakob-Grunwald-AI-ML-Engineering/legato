import SwiftUI

/// Only the header changes channels; draft word taps and selection retain their existing gestures.
public struct DraftInputHeader: View {
    let active: Bool
    let onSelect: () -> Void
    public init(active: Bool, onSelect: @escaping () -> Void) { self.active = active; self.onSelect = onSelect }
    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text("Draft").fontWeight(.medium)
                if active { Circle().fill(Color.accentColor).frame(width: 4, height: 4) }
                Spacer(minLength: 0)
            }
            .font(.caption2).foregroundStyle(active ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Dictation input")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
