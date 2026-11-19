import LegatoComposerUI
import LegatoKeyboardCore
import SwiftUI

/// The word row: three slots with thin dividers, the best suggestion in the middle ("2 | 1 | 3", see
/// `WordRowLayout`), each a button that applies its word (`KeyboardController.suggestionTapped`). A hint, the
/// meeting notice or the dictation status takes the row over while it is active, and the row shows no words then.
/// A slot's word changes as the system's bar does it: letter by letter (`MorphingWord`). While a slot is pressed a
/// capsule fills it and its neighbouring dividers go. It fills the native prediction frame it is given.
struct WordRowView: View {
    let controller: KeyboardController
    /// How many slots the width allows (`WordRowLayout.visibleSlots`).
    let slots: Int
    var fontSize: CGFloat = 17

    /// The slot being pressed (its position in the row), if any: its pill shows and the dividers beside it hide.
    @State private var pressed: Int?

    var body: some View {
        Group {
            if controller.isShowingPreview, let preview = controller.statusText {
                // A take in progress owns the row; kept text (an earlier one or this take's own) returns when it ends.
                previewRow(preview)
            } else if let kept = controller.keptText, kept.isShowable {
                keptRow(kept)
            } else if let recovery = controller.liveRecoveryNotice {
                HStack(spacing: 8) {
                    // Plain text (nothing to tap but Dismiss); it fits in two lines, shrinking rather than cutting off.
                    Text(recovery)
                        .font(.system(size: fontSize - 4))
                        .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.isStaticText)
                    takeButton("Dismiss", id: "keyboard.liveRecovery.dismiss") { controller.dismissLiveRecovery() }
                }
                .padding(.horizontal, CGFloat(WordRowLayout.contentInset))
                .accessibilityIdentifier("keyboard.liveRecovery")
            } else if controller.offersAutoFillSwitch, let target = controller.inputModeTarget {
                AutoFillSwitchKey(target: target)
            } else if controller.hint == nil, let presentation = controller.instructionPresentation {
                InstructionRowView(controller: controller, presentation: presentation, fontSize: fontSize)
                    .transition(.opacity)
            } else if let status = controller.statusText {
                HStack(spacing: 8) {
                    if controller.isCleaningUp {
                        // The take's cleanup is pending or still landing: not time to send yet.
                        ProgressView().controlSize(.small).accessibilityIdentifier("keyboard.cleanup.spinner")
                    }
                    Text(status)
                        .font(.system(size: fontSize - 4))
                        .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                        .lineLimit(2)
                        // Live dictated text: its end matters; a hint reads from the start.
                        .truncationMode(controller.hint == nil ? .head : .tail)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        // Beside the spinner the two stay together, centred.
                        .frame(maxWidth: controller.isCleaningUp ? nil : .infinity)
                        .accessibilityIdentifier("keyboard.hint")
                    if controller.takeFailed {
                        takeButton("Retry", id: "keyboard.take.retry") { controller.retryTake() }
                        takeButton("Insert as-is", id: "keyboard.take.insertRaw") { controller.insertTakeRaw() }
                    }
                }
                .padding(.horizontal, CGFloat(WordRowLayout.contentInset))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
                // After a pause: the rim fills toward the moment the take is sent.
                .overlay {
                    CountdownRim(shape: Capsule(), start: controller.takeCountdown?.start, deadline: controller.takeCountdown?.deadline, lineWidth: 2)
                        .padding(.vertical, 3)
                }
                .transition(.opacity)
            } else {
                row.transition(.opacity)
            }
        }
        // The status (or a hint) takes the row over and gives it back with a plain short fade.
        .animation(controller.isShowingPreview ? nil : .easeOut(duration: 0.12), value: controller.statusText)
    }

    /// The dictation preview (#312): the words not in the field yet, left aligned, two lines, anchored on the newest words. The
    /// text keeps its natural wrapping and sits at the row's bottom edge, so a growing text pushes the oldest line out at the
    /// top and nothing re-centres or jumps. The row keeps its height; the font is the largest that fits two lines with air
    /// between them and clear of the row's edges (`WordRowHeight`, an estimate to measure on the phone).
    private func previewRow(_ text: String) -> some View {
        PreviewRow(text: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("keyboard.hint")
        .transition(.identity)
    }

    private func takeButton(_ title: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: fontSize - 4, weight: .semibold))
                .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color(uiColor: KeyColors.suggestion).opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier(id)
    }

    /// Text the keyboard could not place: its end, then Insert and Copy (Copy needs Full Access), and a small close.
    private func keptRow(_ kept: KeptText) -> some View {
        HStack(spacing: 8) {
            if let notice = controller.keptInsertNotice {
                // Short and readable; it gives the sentence's place back after a moment.
                Text(notice)
                    .font(.system(size: fontSize - 4, weight: .medium))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("keyboard.kept.notice")
            } else {
                // Unsent dictation: a quiet cue, then the start of the sentence so it is recognisable.
                Image(systemName: "waveform")
                    .font(.system(size: fontSize - 6, weight: .medium))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion).opacity(0.7))
                    .accessibilityHidden(true)
                Text(kept.preview(maxCharacters: 120))
                    .font(.system(size: fontSize - 4))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Unsent dictation: \(kept.preview(maxCharacters: 120))")
                    .accessibilityIdentifier("keyboard.kept.text")
            }
            if kept.offersInsertion, kept.insertion == nil || controller.insertingKeptText {
                takeButton(controller.insertingKeptText ? "Inserting…" : "Insert", id: "keyboard.kept.insert",
                           enabled: controller.canInsertKeptText) { controller.insertKeptText() }
                    .accessibilityLabel("Insert at cursor")
            } else if kept.offersInsertion {
                Text("Check the field").font(.system(size: fontSize - 5))
                    .accessibilityLabel("Previous insertion could not be confirmed. You can still copy or dismiss the recovery text.")
            }
            if controller.fullAccess, controller.keptInsertNotice == nil {
                takeButton("Copy", id: "keyboard.kept.copy") { controller.copyKeptText() }
            }
            Button { controller.dismissKeptText() } label: {
                Image(systemName: "xmark").font(.system(size: fontSize - 6, weight: .semibold))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion).opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard kept text")
            .accessibilityIdentifier("keyboard.kept.dismiss")
        }
        .padding(.horizontal, CGFloat(WordRowLayout.contentInset))
        .accessibilityIdentifier("keyboard.kept")
    }

    private var row: some View {
        let ranks = WordRowLayout.ranks(visibleSlots: slots)
        let words = controller.suggestions
        let highlighted = controller.highlightedSuggestionRank.flatMap { ranks.firstIndex(of: $0) }
        return HStack(spacing: 0) {
            ForEach(Array(ranks.enumerated()), id: \.offset) { position, rank in
                SuggestionSlot(controller: controller, word: rank < words.count ? words[rank] : nil,
                               rank: rank, fontSize: fontSize, highlighted: highlighted == position,
                               onPressChange: { isPressed in
                    if isPressed { pressed = position } else if pressed == position { pressed = nil }
                })
                    .overlay(alignment: .trailing) {
                        // The system's bar drops the dividers beside the pressed pill, without animation.
                        if position < ranks.count - 1 {
                            Rectangle().fill(Color(uiColor: KeyColors.divider))
                                .frame(width: 0.67, height: 24)
                                .opacity(words.isEmpty || pressed == position || pressed == position + 1
                                         || highlighted == position || highlighted == position + 1 ? 0 : 1)
                                .transaction { $0.animation = nil }
                        }
                    }
            }
        }
    }

}

/// Keeps the touch-down proposal while asynchronous results may update the same visual slot.
private struct SuggestionSlot: View {
    let controller: KeyboardController
    let word: String?
    let rank: Int
    let fontSize: CGFloat
    let highlighted: Bool
    let onPressChange: (Bool) -> Void
    @State private var press = SuggestionPress()

    var body: some View {
        Button {
            if let tap = press.activate(current: nil) { controller.suggestionTapped(tap) }
        } label: {
            MorphingWord(text: word ?? "", fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(WordSlotStyle(highlighted: highlighted, onPressChange: { isPressed in
            if isPressed { press.began(controller.suggestionTap(rank: rank)) }
            onPressChange(isPressed)
        }))
        .disabled(word == nil)
        .accessibilityHidden(word == nil)
        .accessibilityLabel(word ?? "")
        .accessibilityHint(highlighted ? "Spelling correction. Tap to replace the word being typed." : "Tap to insert suggestion.")
        .accessibilityIdentifier("keyboard.word.\(rank)")
        .accessibilityAction {
            // A canceled touch can leave its token behind. VoiceOver activates the announced row,
            // independently of that touch; ordinary Button actions always keep their frozen token.
            if let tap = press.activate(current: controller.suggestionTap(rank: rank), accessibility: true) {
                controller.suggestionTapped(tap)
            }
        }
    }
}

/// A word slot's press: a capsule across the whole slot (a little shorter than it), white over the bar, which
/// appears and disappears within one frame, as on the system's bar.
private struct WordSlotStyle: ButtonStyle {
    let highlighted: Bool
    let onPressChange: (Bool) -> Void

    /// The system's pill is white at about 30% over the light bar; in dark mode the same lift needs less.
    private static let pill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.15) : UIColor(white: 1, alpha: 0.3) })

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule(style: .continuous)
                    .fill(Self.pill)
                    .padding(.vertical, 4)
                    .opacity(configuration.isPressed || highlighted ? 1 : 0)
                    .transaction { $0.animation = nil }
            }
            .onChange(of: configuration.isPressed) { _, isPressed in onPressChange(isPressed) }
    }
}

/// One slot's word as glyphs that change like the system's suggestion bar: letters both texts share stay and glide
/// to their new places, removed ones fade out right to left, and new ones grow and fade in left to right around
/// their baseline. Each glyph is its own `Text` (a stable view per `GlyphMorph` id), so the word
/// loses the kerning a whole-word `Text` has. The slot is one accessibility element: the word.
private struct MorphingWord: View {
    let text: String
    let fontSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .transition(GlyphReveal(id: glyph.id, staggers: staggers,
                                                baseline: glyphBaseline, reduceMotion: reduceMotion))
                }
            }
            .scaleEffect(scale, anchor: .leading)
            .offset(x: (geometry.size.width - anchorWidth * scale) / 2)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .onChange(of: text) { _, new in
            let next = morph.morphing(to: new)
            staggers.record(next)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                morph = next
                if !next.glyphs.isEmpty { anchorWidth = Self.naturalWidth(of: next, fontSize: fontSize) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// Scale new glyphs around the font baseline so their feet stay level with retained letters.
    private var glyphBaseline: UnitPoint {
        let font = UIFont.systemFont(ofSize: fontSize)
        return UnitPoint(x: 0.5, y: font.ascender / font.lineHeight)
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

    /// A short grow/fade, staggered from the left after the old glyphs begin disappearing.
    func insertionAnimation(_ id: Int) -> Animation {
        .easeOut(duration: 0.18).delay(Self.step * Double(insertion[id] ?? 0) + (hasRemovals ? 0.08 : 0))
    }
}

/// The phone reference shows new letters growing toward their settled size while retained letters slide.
/// The initial scale is a restrained approximation; the capture establishes growth, not Apple's hidden start value.
private struct GlyphReveal: Transition {
    let id: Int
    let staggers: GlyphStaggers
    let baseline: UnitPoint
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase == .willAppear && !reduceMotion ? 0.85 : 1, anchor: baseline)
            .opacity(phase.isIdentity ? 1 : 0)
            .animation(reduceMotion ? nil : phase == .didDisappear
                       ? staggers.removalAnimation(id) : staggers.insertionAnimation(id), value: phase.isIdentity)
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
            #if DEBUG
            button.addAction(UIAction { _ in NSLog("kbd.system-switch request=autofill-picker-touch") }, for: .touchDown)
            #endif
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}

/// The dictation preview text: a clearly readable secondary colour, one line centred vertically, two lines filling the row, and
/// a soft fade at the first line's leading edge when the head of the text is cut off.
private struct PreviewRow: View {
    let text: String
    @State private var textHeight = 0.0

    var body: some View {
        GeometryReader { proxy in
            let height = Double(proxy.size.height)
            let size = WordRowHeight.previewFontSize(rowHeight: height)
            let single = WordRowHeight.previewIsSingleLine(textHeight: textHeight, size: size)
            let truncated = WordRowHeight.previewTruncated(textHeight: textHeight, rowHeight: height, prefixed: text.hasPrefix("…"))
            Text(text)
                .font(.system(size: CGFloat(size)))
                .lineSpacing(CGFloat(WordRowHeight.previewLineSpacing(size: size)))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { textHeight = $0 }
                .frame(width: max(proxy.size.width - 2 * CGFloat(WordRowLayout.previewInset), 0), alignment: .leading)
                .padding(.horizontal, CGFloat(WordRowLayout.previewInset))
                .padding(.bottom, single ? 0 : CGFloat(WordRowHeight.previewPadding(rowHeight: height, size: size)))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: single ? .leading : .bottomLeading)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        // The first line's leading edge; the second line is solid.
                        HStack(spacing: 0) {
                            Color.black.frame(width: CGFloat(WordRowLayout.previewInset))
                            LinearGradient(colors: [truncated ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: CGFloat(WordRowHeight.previewFadeWidth))
                            Color.black
                        }
                        .frame(height: proxy.size.height / 2)
                        Color.black
                    }
                }
        }
    }
}
