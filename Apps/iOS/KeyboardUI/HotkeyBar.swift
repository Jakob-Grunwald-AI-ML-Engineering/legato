import LegatoKeyboardCore
import SwiftUI

/// Undo, redo and Refine: ↶ ↷ undo and redo the keyboard's own edits, Refine asks the app for a stronger
/// rewrite of the last dictation. Dimmed while there is nothing to do (and ↶ ↷ while a run is active in the
/// field). Three equal buttons that fill the frame given; the strip uses them icon-only.
struct HotkeyButtons<Swipe: Gesture>: View {
    let controller: KeyboardController
    /// Refine as a wand icon instead of the word (the strip).
    var iconOnlyRefine = false
    var dividers = true
    /// Whether there is room for redo (the narrowest strip rows leave it out, `StripRow.showsRedo`).
    var showsRedo = true
    let swipe: Swipe

    var body: some View {
        HStack(spacing: 0) {
            key(enabled: controller.canUndo, id: "keyboard.hotkey.undo", label: "Undo", action: controller.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            divider
            if showsRedo {
                key(enabled: controller.canRedo, id: "keyboard.hotkey.redo", label: "Redo", action: controller.redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
                divider
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

    @ViewBuilder
    private var divider: some View {
        if dividers { Rectangle().fill(Color(uiColor: KeyColors.divider)).frame(width: 0.67, height: 24) }
    }

    private func key<Content: View>(
        enabled: Bool, id: String, label: String, action: @escaping () -> Void, tappableWhenDimmed: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 17))
                .foregroundStyle(Color(uiColor: KeyColors.suggestion).opacity(enabled ? 1 : 0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !tappableWhenDimmed)
        .simultaneousGesture(swipe)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The full keyboard's bar: ⌄ (back to the strip, in a strip session) then ↶ ↷ Refine.
struct HotkeyBar<Swipe: Gesture>: View {
    let controller: KeyboardController
    let swipe: Swipe

    var body: some View {
        HStack(spacing: 0) {
            if controller.expansion.control == .collapse {
                ExpansionKey(controller: controller, symbol: "chevron.down")
                    .frame(width: 44)
                    .simultaneousGesture(swipe)
            }
            HotkeyButtons(controller: controller, swipe: swipe)
        }
    }
}
