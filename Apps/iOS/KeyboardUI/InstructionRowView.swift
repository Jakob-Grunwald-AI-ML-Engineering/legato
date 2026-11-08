import LegatoKeyboardCore
import SwiftUI

/// The word row while instruction mode has something to show (`InstructionStripPresentation`): the live instruction,
/// the walk of the field, the work, then the result with Accept and Undo, or a failure with Retry (and Undo). Drawn
/// like the dictation status that shares the row (`WordRowView`): the same type, color and capsule buttons.
struct InstructionRowView: View {
    let controller: KeyboardController
    let presentation: InstructionStripPresentation
    var fontSize: CGFloat = 17

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(presentation.text)
                .font(.system(size: fontSize - 4))
                .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                .lineLimit(2)
                // Live instruction words: their end matters; a status reads from the start.
                .truncationMode(presentation.isTranscript ? .head : .tail)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(presentation.spokenText)
                .accessibilityIdentifier("instruction.text")
            if presentation.showsRetry { button("Retry", id: "instruction.retry") { controller.instructionIntent(.run) } }
            if presentation.showsUndo { button("Undo", id: "instruction.undo") { controller.instructionIntent(.undo) } }
            if presentation.showsAccept { button("Accept", id: "instruction.accept", prominent: true) { controller.instructionIntent(.accept) } }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("instruction.row.\(presentation.kind.rawValue)")
        .onChange(of: presentation.kind) { _, kind in announce(kind) }
    }

    @ViewBuilder private var icon: some View {
        switch presentation.kind {
        case .listening:
            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true).accessibilityHidden(true)
        case .reading, .running:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .result:
            Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
        case .undone:
            Image(systemName: "arrow.uturn.backward.circle").accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
        }
    }

    /// A capsule like the dictation status's buttons; the one that keeps the result is filled in the accent color.
    private func button(_ title: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: fontSize - 4, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color(uiColor: KeyColors.suggestion))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(prominent ? Color(uiColor: KeyColors.accent) : Color(uiColor: KeyColors.suggestion).opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /// VoiceOver does not see the row change by itself: say what came out of the instruction.
    private func announce(_ kind: InstructionStripPresentation.Kind) {
        switch kind {
        case .result, .undone, .failed: AccessibilityNotification.Announcement(presentation.spokenText).post()
        case .listening, .reading, .running: break
        }
    }
}
