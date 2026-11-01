import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The ABC surface, which dictates into the target field: the word row (live words while dictating), the tool row
/// (undo, redo, the way back to the composer and the dictation mic) and the native key grid, at the pre-offshoot
/// height (`KeyboardHeights.height`). Reuses the original keyboard's touch surface, repeat-delete, cursor pan,
/// alternates and field traits. Geometry: `KeyboardMetrics.swift`.
struct TypingFallbackView: View {
    let controller: KeyboardController
    let onReturn: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = KeyGeometry.screenWidth(in: controller.inputModeTarget?.view.window)
            let g = KeyGeometry(size: geometry.size, landscapeScreenWidth: screenWidth)
            let layout = controller.typing.layout
            let frames = layout.frames(in: geometry.size, landscapeScreenWidth: screenWidth)
            ZStack(alignment: .topLeading) {
                if controller.typing.showsEmojiPanel {
                    place(CGRect(x: 0, y: g.firstRowTop, width: geometry.size.width, height: max(geometry.size.height - g.firstRowTop, 0))) {
                        EmojiPickerView(typing: controller.typing, controller: controller)
                    }
                } else {
                    KeyGrid(typing: controller.typing, layout: layout,
                            presentation: controller.typing.presentation, appearance: controller.appearance,
                            emojiSystemSwitcher: controller.emojiSystemSwitcher)
                    ForEach(frames.filter { $0.id == "globe" || ($0.id == "emoji" && controller.emojiSystemSwitcher) }, id: \.id) { frame in
                        place(frame.cgRect) { GlobeKey(target: controller.inputModeTarget, typing: controller.typing, emoji: frame.id == "emoji") }
                    }
                }
                place(g.wordRowFrame) {
                    WordRowView(controller: controller, slots: WordRowLayout.visibleSlots(width: Double(g.wordRowFrame.width)),
                                contentOffset: WordRowHeight.textOffset(landscape: g.landscape))
                        .accessibilityIdentifier("typing.predictions")
                }
                place(g.hotkeyFrame(buttons: Self.toolKeys)) { toolKeys }
                place(g.micFrame(buttons: Self.toolKeys)) { MicKey(controller: controller) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onAppear { controller.wordRow.contextChanged() }
        }
        .background(Color.black.opacity(0.001))
        .accessibilityIdentifier("typing.fallback")
        .onDisappear {
            controller.typing.endDelete()
            controller.typing.cancelCursorPan()
        }
    }

    /// Undo, redo and the composer key; the mic is the fourth key of the row.
    private static let toolKeys = 3

    private var toolKeys: some View {
        HStack(spacing: 6) {
            key("Undo", symbol: "arrow.uturn.backward", id: "keyboard.hotkey.undo", enabled: controller.canUndo, action: controller.undo)
            key("Redo", symbol: "arrow.uturn.forward", id: "keyboard.hotkey.redo", enabled: controller.canRedo, action: controller.redo)
            key("Composer", symbol: "waveform", id: "typing.composer", enabled: true) {
                controller.typing.endDelete()
                controller.typing.cancelCursorPan()
                controller.typing.closeEmojiPanel()
                onReturn()
            }
        }
    }

    private func key(_ label: String, symbol: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Color(uiColor: KeyColors.ink).opacity(enabled ? 1 : 0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func place<Content: View>(_ frame: CGRect, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}
