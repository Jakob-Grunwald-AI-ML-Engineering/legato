import LegatoKeyboardCore
import SwiftUI

/// A small local palette. Selection uses the keyboard's ordinary typing and undo path.
struct EmojiPickerView: View {
    let typing: TypingModel
    let controller: KeyboardController

    var body: some View {
        VStack(spacing: 4) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 2) {
                    ForEach(EmojiPalette.all, id: \.self) { emoji in
                        Button { typing.insertEmoji(emoji) } label: {
                            Text(emoji).font(.system(size: 28))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("emoji.\(emoji)")
                    }
                }
            }
            HStack(spacing: 6) {
                Button {
                    typing.feedback.tick()
                    typing.closeEmojiPanel()
                } label: {
                    Text("ABC").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Letters")
                .accessibilityIdentifier("emoji.letters")
                if controller.showsGlobe {
                    GlobeKey(target: controller.inputModeTarget, typing: typing)
                        .frame(width: 44)
                }
                StripDeleteKey(typing: typing, insets: EdgeInsets())
                    .frame(width: 56)
            }
            .frame(height: 40)
            .foregroundStyle(Color(uiColor: KeyColors.ink))
            .background(Color(uiColor: KeyColors.key), in: RoundedRectangle(cornerRadius: KeyGeometry.keyRadius))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .background(Color.black.opacity(0.001))
    }
}
