import LegatoKeyboardCore
import SwiftUI

/// Undo, redo and Refine: ↶ ↷ undo and redo the keyboard's own edits, Refine asks the app for a stronger
/// rewrite of the last dictation. Dimmed while there is nothing to do (and ↶ ↷ while a run is active in the
/// field). Three equal buttons that fill the frame given; the strip uses them icon-only.
struct HotkeyButtons<Swipe: Gesture>: View {
    let controller: KeyboardController
    /// Refine as a wand icon instead of the word (the strip).
    var iconOnlyRefine = false
    /// Whether there is room for redo (the narrowest strip rows leave it out, `StripRow.showsRedo`).
    var showsRedo = true
    let swipe: Swipe

    var body: some View {
        HStack(spacing: 6) {
            key(enabled: controller.canUndo, id: "keyboard.hotkey.undo", label: "Undo", action: controller.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            if showsRedo {
                key(enabled: controller.canRedo, id: "keyboard.hotkey.redo", label: "Redo", action: controller.redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
            }
            // Tappable while dimmed: a tap says why it can't run.
            key(enabled: controller.canRefine, id: "keyboard.hotkey.refine", label: "Refine", action: controller.refine, tappableWhenDimmed: true) {
                if controller.isRefining {
                    ProgressView()
                } else if iconOnlyRefine {
                    Image(systemName: "wand.and.stars")
                } else {
                    Text("Refine")
                }
            }
        }
    }

    private func key<Content: View>(
        enabled: Bool, id: String, label: String, action: @escaping () -> Void, tappableWhenDimmed: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 17))
                .foregroundStyle(Color(uiColor: KeyColors.ink).opacity(enabled ? 1 : 0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyButtonStyle())
        .disabled(!enabled && !tappableWhenDimmed)
        .simultaneousGesture(swipe)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The full keyboard's bar: ⌄ (back to the strip, in a strip session) then ↶ ↷ Refine.
struct HotkeyBar<Swipe: Gesture>: View {
    let controller: KeyboardController
    let buttonWidth: CGFloat
    let swipe: Swipe

    var body: some View {
        HStack(spacing: 6) {
            if controller.expansion.control == .collapse {
                ExpansionKey(controller: controller, symbol: "chevron.down")
                    .frame(width: buttonWidth)
                    .simultaneousGesture(swipe)
            }
            HotkeyButtons(controller: controller, swipe: swipe)
        }
    }
}
