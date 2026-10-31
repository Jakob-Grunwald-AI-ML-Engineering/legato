import LegatoKeyboardCore
import LegatoComposerUI
import SwiftUI
import UIKit

/// A fixed-height composer with native actions and a bottom typing utility key.
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme
    @State private var showsModePicker = false
    @State private var showsTypingKeyboard = false
    private let modes = [("message", "message"), ("email", "envelope"), ("prompt", "sparkles"), ("note", "note.text"), ("auto", "wand.and.stars")]

    var body: some View {
        GeometryReader { geometry in
            if showsTypingKeyboard { TypingFallbackView(controller: controller) { showsTypingKeyboard = false } }
            else { composerBody(landscape: KeyGeometry.isLandscape(width: geometry.size.width)) }
        }
    }
    private func composerBody(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                ComposerView(snapshot: controller.composer.snapshot, tail: controller.composer.tail,
                             pendingLineIDs: controller.composer.pendingLineIDs, busy: controller.composer.busy,
                             instructionText: controller.composer.instructionDraft ?? "", instructionStatus: controller.composer.instructionStatus ?? "Ready",
                             instructionInputActive: controller.composer.inputMode == "instructions",
                             correctionDraft: controller.composer.correctionDraft,
                correctionCountdownStart: controller.composer.correctionCountdownStart, correctionCountdownDeadline: controller.composer.correctionCountdownDeadline,
                             onSelect: { controller.composerIntent("tap", lineID: $0.lineID, wordID: $0.wordID, endLineID: $0.endLineID, endWordID: $0.endWordID) },
                             onDeselect: { controller.composerIntent("deselect") },
                             onSendCorrection: { controller.composerIntent("send-correction") },
                             onPick: { controller.composerIntent("pick", lineID: $0, wordID: $1, text: $2) })
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                if let error = controller.composer.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal)
                }
            }
            toolRow(landscape: landscape)
            HStack {
                Button("ABC") { showsModePicker = false; showsTypingKeyboard = true }
                    .font(.system(size: 13, weight: .medium)).frame(width: 44, height: 22)
                    .buttonStyle(KeyButtonStyle()).accessibilityLabel("Typing keyboard")
                    .accessibilityIdentifier("composer.typingKeyboard")
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(uiColor: KeyColors.ink))
            .padding(.horizontal, 6.33).frame(height: ComposerKeyboardLayout.utilityRowHeight)
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
                                           keyWidth: (geometry.size.width - 12.66 - 36) / 7,
                                           maximumHeight: max(0, geometry.size.height - 66), onSelect: { mode in
                            controller.composerIntent("mode", text: mode)
                            showsModePicker = false
                        }, onNewTopic: {
                            controller.composerIntent("new-topic")
                            showsModePicker = false
                        })
                        .frame(width: min(232, geometry.size.width - 12.66))
                        .padding(.leading, 6.33).padding(.bottom, 42 + ComposerKeyboardLayout.utilityRowHeight)
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
            key("Undo", symbol: "arrow.uturn.backward", enabled: controller.canUndo, action: controller.undo)
            key("Redo", symbol: "arrow.uturn.forward", enabled: controller.canRedo, action: controller.redo)
            Button { controller.insertComposer() } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 17))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(controller.composer.snapshot.lines.isEmpty && controller.composer.tail.isEmpty ? 0.35 : 1)
            }.disabled((controller.composer.snapshot.lines.isEmpty && controller.composer.tail.isEmpty) || controller.pendingComposerInsert != nil).accessibilityLabel("Insert")
            key("Cancel composition", symbol: "xmark", action: { controller.composerIntent("cancel") })
            key(controller.composer.inputMode == "instructions" ? "Instructions input" : "Dictation input",
                symbol: controller.composer.inputMode == "instructions" ? "text.bubble.fill" : "waveform",
                selected: controller.composer.inputMode == "instructions",
                action: { controller.composerIntent("input-mode", text: controller.composer.inputMode == "instructions" ? "dictation" : "instructions") })
            MicKey(controller: controller)
        }
        .font(.system(size: 17))
        .foregroundStyle(Color(uiColor: KeyColors.ink))
        .buttonStyle(KeyButtonStyle())
        .padding(.horizontal, 6.33).padding(.top, landscape ? 6 : 8).padding(.bottom, landscape ? 2 : 3).frame(height: landscape ? 35.33 : 54)
        .background(Color.black.opacity(0.001)).contentShape(Rectangle())
    }

    private func key(_ label: String, symbol: String, enabled: Bool = true, selected: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).opacity(enabled ? 1 : 0.35)
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
