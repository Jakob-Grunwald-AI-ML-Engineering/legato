import LegatoKeyboardCore
import SwiftUI
import UIKit

/// Optional typing into the external text field. The voice composition stays in the host unchanged.
/// Reuses the original keyboard's touch surface, repeat-delete, cursor pan, alternates and field traits.
struct TypingFallbackView: View {
    let controller: KeyboardController
    let onReturn: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let landscape = KeyGeometry.isLandscape(width: geometry.size.width)
            let nativeHeight = KeyGeometry.height(landscape: landscape)
            let removedToolRow: CGFloat = landscape ? 35.33 : 54
            let height = min(geometry.size.height, nativeHeight - removedToolRow)
            let top = geometry.size.height - height
            let gridOffset = top - removedToolRow
            let layout = controller.typing.layout
            let frames = layout.frames(in: CGSize(width: geometry.size.width, height: nativeHeight))
            ZStack(alignment: .topLeading) {
                if controller.typing.showsEmojiPanel {
                    EmojiPickerView(typing: controller.typing, controller: controller)
                        .frame(height: max(0, height - 35))
                        .offset(y: top + 35)
                } else {
                    KeyGrid(typing: controller.typing, layout: layout,
                            presentation: controller.typing.presentation, appearance: controller.appearance,
                            emojiSystemSwitcher: controller.emojiSystemSwitcher)
                        .frame(width: geometry.size.width, height: nativeHeight)
                        .offset(y: gridOffset)
                    ForEach(frames.filter { $0.id == "globe" || ($0.id == "emoji" && controller.emojiSystemSwitcher) }, id: \.id) { frame in
                        let rect = frame.cgRect
                        GlobeKey(target: controller.inputModeTarget, typing: controller.typing, emoji: frame.id == "emoji")
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.minX + rect.width / 2,
                                      y: gridOffset + rect.minY + rect.height / 2)
                    }
                }
                HStack {
                    Button {
                        controller.typing.endDelete()
                        controller.typing.cancelCursorPan()
                        controller.typing.closeEmojiPanel()
                        onReturn()
                    } label: {
                        Label("Composer", systemImage: "waveform")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 11)
                            .frame(height: 27)
                    }
                    .buttonStyle(KeyButtonStyle())
                    .accessibilityLabel("Return to voice composer")
                    .accessibilityIdentifier("typing.composer")
                    Spacer()
                    Text("Text field")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color(uiColor: KeyColors.ink))
                .padding(.horizontal, 6.33)
                .frame(height: 29)
                .offset(y: top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(Color.black.opacity(0.001))
        .accessibilityIdentifier("typing.fallback")
        .onDisappear {
            controller.typing.endDelete()
            controller.typing.cancelCursorPan()
        }
    }
}
