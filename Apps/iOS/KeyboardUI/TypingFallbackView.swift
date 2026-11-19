import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The ABC surface, which dictates into the target field: the top row (the dictation key beside the transcript, #315) and
/// the native key grid, at `KeyboardHeights.height`. Reuses the original keyboard's touch surface, repeat-delete, cursor pan,
/// alternates and field traits. Geometry: `KeyboardMetrics.swift`, `TopRowLayout`.
struct TypingFallbackView: View {
    let controller: KeyboardController

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
                        .zIndex(1)  // Its popups reach over the top row; it takes no touches there.
                    ForEach(frames.filter { $0.id == "globe" || ($0.id == "emoji" && controller.emojiSystemSwitcher) }, id: \.id) { frame in
                        place(frame.cgRect) { GlobeKey(target: controller.inputModeTarget, typing: controller.typing, emoji: frame.id == "emoji") }
                            .zIndex(2)
                    }
                }
                TopRowView(controller: controller, layout: g.topRow(mode: .full, side: controller.dictationKeySide))
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
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

    private func place<Content: View>(_ frame: CGRect, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}
