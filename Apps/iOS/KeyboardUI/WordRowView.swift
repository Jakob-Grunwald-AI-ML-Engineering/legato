import LegatoKeyboardCore
import SwiftUI

/// The word row: three slots with thin dividers, the best suggestion in the middle ("2 | 1 | 3", see
/// `WordRowLayout`), each a button that applies its word (`KeyboardController.suggestionTapped`). A hint, the
/// meeting notice or the dictation status takes the row over while it is active, and the row shows no words then.
/// It fills the frame it is given; the parent adds the swipe that toggles the strip.
struct WordRowView<Swipe: Gesture>: View {
    let controller: KeyboardController
    /// How many slots the width allows (`WordRowLayout.visibleSlots`).
    let slots: Int
    var fontSize: CGFloat = 17
    let swipe: Swipe

    var body: some View {
        Group {
            if let status = controller.statusText {
                Text(status)
                    .font(.system(size: fontSize - 4))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                    .lineLimit(2)
                    // Live dictated text: its end matters; a hint reads from the start.
                    .truncationMode(controller.hint == nil ? .head : .tail)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .simultaneousGesture(swipe)
                    .accessibilityIdentifier("keyboard.hint")
            } else {
                row
            }
        }
        // As the system's bar: new words cross-fade in place, nothing slides.
        .animation(.easeOut(duration: 0.18), value: controller.suggestions)
        .animation(.easeOut(duration: 0.18), value: controller.statusText)
    }

    private var row: some View {
        let ranks = WordRowLayout.ranks(visibleSlots: slots)
        let words = controller.suggestions
        return HStack(spacing: 0) {
            ForEach(Array(ranks.enumerated()), id: \.offset) { position, rank in
                let word = rank < words.count ? words[rank] : nil
                slot(word, rank: rank)
                    .overlay(alignment: .trailing) {
                        if position < ranks.count - 1 {
                            Rectangle().fill(Color(uiColor: KeyColors.divider)).frame(width: 0.67, height: 24)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func slot(_ word: String?, rank: Int) -> some View {
        if let word {
            Button { controller.suggestionTapped(rank: rank) } label: {
                Text(word)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
            }
            .buttonStyle(WordSlotStyle())
            .transition(.opacity)
            .simultaneousGesture(swipe)
            .accessibilityLabel(word)
            .accessibilityIdentifier("keyboard.word.\(rank)")
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A word slot's press: a rounded key-colored highlight behind the word, as on the system's bar.
private struct WordSlotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: KeyColors.key))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.2), value: configuration.isPressed)
    }
}
