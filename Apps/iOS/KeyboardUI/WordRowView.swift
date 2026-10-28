import LegatoKeyboardCore
import SwiftUI

/// The word row: three slots with thin dividers, the best suggestion in the middle ("2 | 1 | 3", see
/// `WordRowLayout`), each a button that applies its word (`KeyboardController.suggestionTapped`). A hint, the
/// meeting notice or the dictation status takes the row over while it is active, and the row shows no words then.
/// A slot's word changes as the system's bar does it: letter by letter (`MorphingWord`). While a slot is pressed a
/// capsule fills it and its neighbouring dividers go. It fills the frame it is given; the parent adds the swipe
/// that toggles the strip.
struct WordRowView<Swipe: Gesture>: View {
    let controller: KeyboardController
    /// How many slots the width allows (`WordRowLayout.visibleSlots`).
    let slots: Int
    var fontSize: CGFloat = 17
    let swipe: Swipe

    /// The slot being pressed (its position in the row), if any: its pill shows and the dividers beside it hide.
    @State private var pressed: Int?

    var body: some View {
        Group {
            if controller.offersAutoFillSwitch, let target = controller.inputModeTarget {
                AutoFillSwitchKey(target: target)
            } else if let status = controller.statusText {
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
                    .transition(.opacity)
            } else {
                row.transition(.opacity)
            }
        }
        // The status (or a hint) takes the row over and gives it back with a plain short fade.
        .animation(.easeOut(duration: 0.12), value: controller.statusText)
    }

    private var row: some View {
        let ranks = WordRowLayout.ranks(visibleSlots: slots)
        let words = controller.suggestions
        return HStack(spacing: 0) {
            ForEach(Array(ranks.enumerated()), id: \.offset) { position, rank in
                slot(rank < words.count ? words[rank] : nil, rank: rank, position: position)
                    .overlay(alignment: .trailing) {
                        // The system's bar drops the dividers beside the pressed pill, without animation.
                        if position < ranks.count - 1 {
                            Rectangle().fill(Color(uiColor: KeyColors.divider)).frame(width: 0.67, height: 24)
                                .opacity(pressed == position || pressed == position + 1 ? 0 : 1)
                                .transaction { $0.animation = nil }
                        }
                    }
            }
        }
    }

    /// An empty slot keeps its button (disabled, hidden from accessibility) so its word can fade out in place.
    private func slot(_ word: String?, rank: Int, position: Int) -> some View {
        Button { controller.suggestionTapped(rank: rank) } label: {
            MorphingWord(text: word ?? "", fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(WordSlotStyle(onPressChange: { isPressed in
            if isPressed { pressed = position } else if pressed == position { pressed = nil }
        }))
        .disabled(word == nil)
        .simultaneousGesture(swipe)
        .accessibilityHidden(word == nil)
        .accessibilityLabel(word ?? "")
        .accessibilityIdentifier("keyboard.word.\(rank)")
    }
}

/// A word slot's press: a capsule across the whole slot (a little shorter than it), white over the bar, which
/// appears and disappears within one frame, as on the system's bar.
private struct WordSlotStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    /// The system's pill is white at about 30% over the light bar; in dark mode the same lift needs less.
    private static let pill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.15) : UIColor(white: 1, alpha: 0.3) })

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule(style: .continuous)
                    .fill(Self.pill)
                    .padding(.vertical, 4)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .transaction { $0.animation = nil }
            }
            .onChange(of: configuration.isPressed) { _, isPressed in onPressChange(isPressed) }
    }
}

/// One slot's word as glyphs that change like the system's suggestion bar: letters both texts share stay and glide
/// to their new places, removed ones fade out right to left, inserted ones fade in as the old ones finish; nothing
/// blurs, scales or moves vertically. Each glyph is its own `Text` (a stable view per `GlyphMorph` id), so the word
/// loses the kerning a whole-word `Text` has. The slot is one accessibility element: the word.
private struct MorphingWord: View {
    let text: String
    let fontSize: CGFloat
    @State private var morph: GlyphMorph
    @State private var staggers = GlyphStaggers()
    /// The natural width of the last non-empty word: the word is centered by it, so a word that empties fades out
    /// where it stood instead of drifting toward the middle as its row collapses.
    @State private var anchorWidth: CGFloat

    init(text: String, fontSize: CGFloat) {
        self.text = text
        self.fontSize = fontSize
        let morph = GlyphMorph(text: text)
        _morph = State(initialValue: morph)
        _anchorWidth = State(initialValue: Self.naturalWidth(of: morph, fontSize: fontSize))
    }

    /// The room beside the word inside its slot, and the smallest it is shrunk to inside the rest.
    private static let inset: CGFloat = 6
    private static let minimumScale: CGFloat = 0.7

    var body: some View {
        GeometryReader { geometry in
            let scale = scale(fitting: geometry.size.width - 2 * Self.inset)
            HStack(spacing: 0) {
                // Keeps the row as tall as the slot even with no glyph, so fading glyphs never sink.
                Color.clear.frame(width: 0, height: geometry.size.height)
                ForEach(morph.glyphs) { glyph in
                    Text(String(glyph.character))
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                        .fixedSize()
                        .transition(GlyphFade(id: glyph.id, staggers: staggers))
                }
            }
            .scaleEffect(scale, anchor: .leading)
            .offset(x: (geometry.size.width - anchorWidth * scale) / 2)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .onChange(of: text) { _, new in
            let next = morph.morphing(to: new)
            staggers.record(next)
            withAnimation(.easeInOut(duration: 0.25)) {
                morph = next
                if !next.glyphs.isEmpty { anchorWidth = Self.naturalWidth(of: next, fontSize: fontSize) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// Long words shrink to fit (down to `minimumScale`), as the whole-word `Text` did.
    private func scale(fitting width: CGFloat) -> CGFloat {
        guard anchorWidth > width, anchorWidth > 0 else { return 1 }
        return max(Self.minimumScale, width / anchorWidth)
    }

    /// The glyphs' widths side by side, as the row lays them out (without a whole-word `Text`'s kerning).
    private static func naturalWidth(of morph: GlyphMorph, fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize)
        return morph.glyphs.reduce(CGFloat(0)) { $0 + String($1.character).size(withAttributes: [.font: font]).width }
    }
}

/// The delays of the current change, by glyph id. A transition's body runs when its glyph appears or goes, after
/// the change is recorded here, so a removed glyph can be timed by the change that removes it.
@MainActor
private final class GlyphStaggers {
    private var insertion: [Int: Int] = [:]
    private var removal: [Int: Int] = [:]
    private var hasRemovals = false

    private static let step = 0.03

    func record(_ morph: GlyphMorph) {
        insertion = morph.insertionStagger
        removal = Dictionary(uniqueKeysWithValues: morph.removals.map { ($0.glyph.id, $0.stagger) })
        hasRemovals = !morph.removals.isEmpty
    }

    /// 100 ms steep ease-out, one step later per glyph further left.
    func removalAnimation(_ id: Int) -> Animation {
        .easeOut(duration: 0.1).delay(Self.step * Double(removal[id] ?? 0))
    }

    /// 120 ms ease-out, starting as the removed glyphs finish (at once when nothing is removed).
    func insertionAnimation(_ id: Int) -> Animation {
        .easeOut(duration: 0.12).delay(Self.step * Double(insertion[id] ?? 0) + (hasRemovals ? 0.08 : 0))
    }
}

/// Fade only: opacity with the glyph's own delay.
private struct GlyphFade: Transition {
    let id: Int
    let staggers: GlyphStaggers

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .animation(phase == .didDisappear ? staggers.removalAnimation(id) : staggers.insertionAnimation(id), value: phase.isIdentity)
    }
}

/// UIKit receives all touches so the system supplies both tap-to-advance and the long-press picker.
/// iOS chooses the next enabled keyboard; a keyboard extension cannot select Apple Passwords directly.
private struct AutoFillSwitchKey: UIViewRepresentable {
    weak var target: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "key.fill")
        configuration.title = "Switch keyboard for AutoFill"
        configuration.imagePadding = 5
        configuration.baseForegroundColor = KeyColors.suggestion
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = UIFont.systemFont(ofSize: 13)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "keyboard.autofill"
        button.accessibilityLabel = "Switch keyboard for AutoFill"
        button.accessibilityHint = "Switches to the next keyboard. Touch and hold to choose a keyboard."
        if let target {
            button.addTarget(target, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}
