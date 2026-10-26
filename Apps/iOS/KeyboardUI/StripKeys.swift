import LegatoKeyboardCore
import SwiftUI

/// A key of the strip that acts on touch-down and touch-up itself (delete repeats while held), drawn like the
/// full keyboard's keys: fill, radius, pressed fill. Not a `Button`: a button gives no touch-down. It fills
/// the touch area it is given; the key is drawn inset by `insets`, so the area around it takes touches too.
///
/// - `onPress`: the finger went down (feedback, delete).
/// - `onRelease`: the touch is over, however it ended (lifted, cancelled by iOS, the view left); may come without a press.
/// - `onTap`: lifted without having moved; a swipe that starts on the key does not tap it.
/// The parent adds the strip's `.simultaneousGesture(swipe)`.
struct StripKey<Label: View>: View {
    var insets: EdgeInsets
    var fill: UIColor = KeyColors.key
    var pressedFill: UIColor = KeyColors.pressed
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    let onTap: () -> Void
    @ViewBuilder let label: (_ pressed: Bool) -> Label

    /// The most a finger may travel and still be a tap.
    private static var tapSlop: CGFloat { 10 }

    @GestureState private var down = false

    var body: some View {
        label(down)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(insets)
            .background(
                RoundedRectangle(cornerRadius: KeyGeometry.keyRadius)
                    .fill(Color(uiColor: down ? pressedFill : fill))
                    .padding(insets))
            // Not clear: the keyboard gets no touches on fully clear pixels.
            .background(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($down) { _, state, _ in state = true }
                    .onEnded { value in
                        if hypot(value.translation.width, value.translation.height) < Self.tapSlop { onTap() }
                    })
            .onChange(of: down) { _, isDown in
                if isDown { onPress() } else { onRelease() }
            }
            .onDisappear { onRelease() }
    }
}

/// The strip's delete key: one character on touch-down, then repeating while held, exactly the full
/// keyboard's (`TypingModel.beginDelete`, `DeleteRepeater`).
struct StripDeleteKey: View {
    let typing: TypingModel
    let insets: EdgeInsets

    var body: some View {
        StripKey(
            insets: insets,
            onPress: {
                typing.feedback.tick()
                typing.beginDelete()
            },
            onRelease: { typing.endDelete() },
            onTap: {}
        ) { pressed in
            Image(systemName: pressed ? "delete.left.fill" : "delete.left")
                .font(.system(size: 19))
                .foregroundStyle(Color(uiColor: KeyColors.ink))
        }
        .accessibilityElement()
        .accessibilityLabel("Delete")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("key.delete")
        .accessibilityAction {
            typing.beginDelete()
            typing.endDelete()
        }
    }
}

/// The strip's return key: a newline on lift, captioned and colored by the host's return key type like the
/// full keyboard's (`KeyLabels.returnSymbol`, accent fill for an action, dimmed while the field disables it).
struct StripReturnKey: View {
    let typing: TypingModel
    let insets: EdgeInsets

    var body: some View {
        let presentation = typing.presentation
        let prominent = presentation.returnProminent && presentation.returnEnabled
        let ink: UIColor = prominent ? .white : presentation.returnEnabled ? KeyColors.ink : KeyColors.ink.withAlphaComponent(0.3)
        StripKey(
            insets: insets,
            fill: prominent ? KeyColors.accent : KeyColors.key,
            pressedFill: prominent ? KeyColors.accent.withAlphaComponent(0.7) : KeyColors.pressed,
            onPress: { typing.feedback.tick() },
            onTap: { typing.tapReturn() }
        ) { _ in
            Group {
                if let symbol = KeyLabels.returnSymbol(for: presentation.returnLabel) {
                    Image(systemName: symbol.name)
                        .font(.system(size: 19, weight: symbol.weight == .medium ? .medium : .regular))
                } else {
                    Text(presentation.returnLabel)
                        .font(.system(size: 17))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(Color(uiColor: ink))
        }
        .accessibilityElement()
        .accessibilityLabel(presentation.returnLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("key.return")
        .accessibilityAction { typing.tapReturn() }
    }
}
