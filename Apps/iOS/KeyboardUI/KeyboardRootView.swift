import LegatoKeyboardCore
import LegatoComposerUI
import SwiftUI
import UIKit

/// A fixed-height composer with native actions and a bottom typing utility key. The surface shown is the
/// mode: typing dictates into the field, the composer instructs the agent (`KeyboardController.show`).
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme
    @State private var showsModePicker = false
    private let modes = [("message", "message"), ("email", "envelope"), ("prompt", "sparkles"), ("note", "note.text"), ("auto", "wand.and.stars")]

    var body: some View {
        GeometryReader { geometry in
            if controller.surface == .typing { TypingFallbackView(controller: controller) { controller.show(.composer) } }
            else { composerBody(landscape: KeyGeometry.isLandscape(width: geometry.size.width)) }
        }
    }
    private func composerBody(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                ComposerView(snapshot: controller.composer.snapshot, tail: controller.composer.tail,
                             dictationRevision: controller.composer.dictationRevision ?? 0, dictationCommit: controller.composer.dictationCommit, successfulInsertionID: controller.composer.successfulInsertionID,
                             pendingLineIDs: controller.composer.pendingLineIDs, busy: controller.composer.busy,
                             instructionText: controller.composer.instructionDraft ?? "", instructionStatus: controller.composer.instructionStatus ?? "Ready",
                             instructionInputActive: false,
                             correctionDraft: controller.composer.correctionDraft, correctionSubmitting: controller.composer.correctionSubmitting ?? false,
                correctionCountdownStart: controller.composer.correctionCountdownStart, correctionCountdownDeadline: controller.composer.correctionCountdownDeadline,
                             onSelect: { controller.composerIntent("tap", lineID: $0.lineID, wordID: $0.wordID, endLineID: $0.endLineID, endWordID: $0.endWordID) },
                             onDeselect: { controller.composerIntent("deselect") },
                             onSendCorrection: { controller.composerIntent("send-correction") },
                             onSendInstruction: { controller.composerIntent("send-instruction") },
                             onDiscardInstruction: { controller.composerIntent("discard-instruction") },
                             onPick: { controller.composerIntent("pick", lineID: $0, wordID: $1, text: $2) })
                    .frame(maxHeight: .infinity)
                if let error = controller.composer.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal)
                }
            }
            toolRow(landscape: landscape)

        }
        // UIInputView(.keyboard) supplies the system cap/tray material. Nonzero alpha keeps blank pixels touchable.
        .background(Color.black.opacity(0.001))
        .environment(\.colorScheme, scheme)
        .overlay {
            if showsModePicker {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle())
                            .onTapGesture { showsModePicker = false }
                            .accessibilityLabel("Dismiss writing modes")
                            .accessibilityAddTraits(.isButton)
                        KeyboardModePicker(modes: modes, selected: controller.composer.mode,
                                           keyWidth: (geometry.size.width - 12.66 - 30) / 6,
                                           maximumHeight: max(0, geometry.size.height - 66), onSelect: { mode in
                            controller.composerIntent("mode", text: mode)
                            showsModePicker = false
                        }, onNewTopic: {
                            controller.composerIntent("new-topic")
                            showsModePicker = false
                        })
                        .frame(width: min(232, geometry.size.width - 12.66))
                        .padding(.leading, 6.33).padding(.bottom, 42)
                    }
                    .accessibilityAction(.escape) { showsModePicker = false }
                }
            }
        }
        .onDisappear { showsModePicker = false }
    }

    private func toolRow(landscape: Bool) -> some View {
        HStack(spacing: 6) {
            Button { showsModePicker.toggle() } label: {
                Image(systemName: modes.first(where: { $0.0 == controller.composer.mode })?.1 ?? "message")
                    .font(.system(size: 18)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(KeyboardModeKeyStyle(expanded: showsModePicker))
            .accessibilityLabel(controller.composer.mode.capitalized)
            .accessibilityHint("Choose a writing mode")
            key("ABC", action: { showsModePicker = false; controller.show(.typing) })
                .accessibilityHint("Typing keyboard")
                .accessibilityIdentifier("composer.typingKeyboard")
            Button { controller.insertComposer() } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 17))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(controller.composer.snapshot.lines.isEmpty && controller.composer.tail.isEmpty ? 0.35 : 1)
            }.disabled((controller.composer.snapshot.lines.isEmpty && controller.composer.tail.isEmpty) || controller.pendingComposerInsert != nil).accessibilityLabel("Insert")
            key("Cancel composition", symbol: "xmark", action: { controller.composerIntent("cancel") })
            MicKey(controller: controller)
        }
        .font(.system(size: 17))
        .foregroundStyle(Color(uiColor: KeyColors.ink))
        .buttonStyle(KeyButtonStyle())
        .padding(.horizontal, 6.33).padding(.top, landscape ? 6 : 8).padding(.bottom, landscape ? 2 : 3).frame(height: landscape ? 35.33 : 54)
        .background(Color.black.opacity(0.001)).contentShape(Rectangle())
    }

    private func key(_ label: String, symbol: String? = nil, enabled: Bool = true, selected: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) }
                else { Text(label) }
            }
            .opacity(enabled ? 1 : 0.35)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(KeyButtonStyle(selected: selected))
        .disabled(!enabled).accessibilityLabel(label)
    }

    private var scheme: ColorScheme {
        switch controller.appearance {
        case .dark: .dark
        case .light: .light
        default: systemScheme
        }
    }
}
