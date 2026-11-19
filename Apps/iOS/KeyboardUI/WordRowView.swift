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
    /// The preview's touch bloom, kept here: the row's content changes under it (the preview gives way to a cleanup status and
    /// back), and the bloom runs its whole duration across the row, whichever it shows.
    @State private var bloom: (point: CGPoint, start: Date)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if controller.isShowingPreview, let preview = controller.statusText {
                // A take in progress owns the row.
                previewRow(preview)
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
        .overlay { bloomOverlay }
        .onChange(of: bloom?.start) { _, start in
            guard let start else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(Self.bloomSeconds * 1000) + 100))
                if bloom?.start == start { bloom = nil }
            }
        }
    }

    private static let bloomSeconds = 0.35

    /// A soft bloom of the magic colours growing from the touch point across the whole row (350 ms, low opacity); with Reduce
    /// Motion a brief plain highlight.
    @ViewBuilder
    private var bloomOverlay: some View {
        if let bloom {
            TimelineView(.animation) { timeline in
                let t = min(1, max(0, timeline.date.timeIntervalSince(bloom.start) / (reduceMotion ? 0.2 : Self.bloomSeconds)))
                Canvas { context, canvas in
                    let whole = Path(CGRect(origin: .zero, size: canvas))
                    if reduceMotion {
                        context.fill(whole, with: .color(Color.primary.opacity(0.1 * (1 - t))))
                        return
                    }
                    let reach = max(hypot(bloom.point.x, bloom.point.y), hypot(canvas.width - bloom.point.x, bloom.point.y),
                                    hypot(bloom.point.x, canvas.height - bloom.point.y), hypot(canvas.width - bloom.point.x, canvas.height - bloom.point.y))
                    let radius = max(1, reach * (1 - (1 - t) * (1 - t)))
                    // Soft: it peaks early and is gone by the end.
                    let colors = MagicGradient.colors.map { $0.opacity(0.4 * (1 - t) * (1 - t)) }
                    context.fill(whole, with: .radialGradient(Gradient(colors: colors + [.clear]), center: bloom.point,
                                                              startRadius: 0, endRadius: radius))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The dictation preview (#312): the words not in the field yet, left aligned, two lines, anchored on the newest words. The
    /// text keeps its natural wrapping and sits at the row's bottom edge, so a growing text pushes the oldest line out at the
    /// top and nothing re-centres or jumps. The row keeps its height; the font is the largest that fits two lines with air
    /// between them and clear of the row's edges (`WordRowHeight`, an estimate to measure on the phone).
    private func previewRow(_ text: String) -> some View {
        PreviewRow(text: text, layout: controller.dictationPreviewLayout, canSend: controller.canSendPreview,
                   onSend: { point in bloom = (point, Date()); controller.previewTapped() },
                   onSendRaw: { controller.previewSwiped() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint(controller.canSendPreview ? "Tap to send what you have said so far." : "")
        .accessibilityAddTraits(controller.canSendPreview ? .isButton : [])
        .accessibilityAction { if controller.canSendPreview { controller.previewTapped() } }
        .accessibilityAction(named: "Insert without cleanup") { if controller.canSendPreview { controller.previewSwiped() } }
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

/// How a run of the preview text is drawn (`PreviewRenderer`): the unit being typed into the field, or closed words waiting
/// for their cleanup.
private enum PreviewRole: TextAttribute { case leaving, waiting }

/// Draws the preview with per-glyph effects, by role, and leaves every glyph in its place so nothing reflows:
/// - leaving glyphs lift `lift` and fade over `fadeSeconds` from their own exit time (the unit's letters, as the field types them);
/// - waiting glyphs (closed units whose cleanup has not landed: "thinking") carry a slow magic-coloured shimmer, the only use
///   of the magic colours here; words entering are plain (`hidden`: the glyphs not typed in yet are not drawn).
/// The lift, fade length and shimmer period are estimates, to tune on the phone.
/// The preview's vertical window while a unit leaves: the lines the text has been moved up by, animated between whole lines.
/// Drawing keeps this clock because the line the letters leave from is only known from the laid-out text.
private final class ExitScroll {
    private var from = 0.0, target = 0.0, since = Date.distantPast
    static let seconds = 0.25

    func value(toward newTarget: Double, at now: Date) -> Double {
        let current = self.current(at: now)
        if newTarget != target { from = current; target = newTarget; since = now }
        return self.current(at: now)
    }

    private func current(at now: Date) -> Double {
        let t = min(1, max(0, now.timeIntervalSince(since) / Self.seconds))
        return from + (target - from) * (1 - (1 - t) * (1 - t))
    }
}

/// The plain typewriter reveal of words entering the preview: how many trailing characters of the text are still hidden. Growth
/// (new words appended, the head possibly cut off at the front) types in at `TypewriterDrain`'s pace; any other change shows at
/// once. No colour: revealed glyphs are drawn like all the rest. Drawing keeps this clock, like `ExitScroll`.
private final class PreviewReveal {
    private var text = ""
    private var last = Date.distantPast
    private(set) var hidden = 0

    private static func body(_ text: String) -> String { text.hasPrefix("…") ? String(text.dropFirst()) : text }

    /// The text of this frame: what it adds to the previous one is hidden from the end. The `placeholder` is not words: it
    /// shows at once and the first words after it type in from nothing.
    func update(text newText: String, placeholder: String, enabled: Bool) {
        guard newText != text else { return }
        let old = text == placeholder ? "" : text
        defer { text = newText }
        let new = Self.body(newText), prior = Self.body(old)
        guard enabled, newText != placeholder, !new.isEmpty else { hidden = 0; return }
        guard !prior.isEmpty else { hidden = new.count; return }
        // The old text, minus a head the preview cut off, is the start of the new one.
        let oldChars = Array(prior), newChars = Array(new)
        for cut in 0..<oldChars.count where newChars.starts(with: oldChars[cut...]) {
            hidden = min(newChars.count, hidden + newChars.count - (oldChars.count - cut))
            return
        }
        hidden = 0
    }

    /// Hides fewer characters as time passes; true once everything is shown.
    func advance(now: Date, total: Int) -> Bool {
        let dt = min(100, max(0, now.timeIntervalSince(last) * 1000))
        last = now
        guard hidden > 0 else { return true }
        let revealed = TypewriterDrain.step(revealed: max(0, total - hidden), target: total, dtMs: dt)
        hidden = max(0, total - revealed)
        return hidden == 0
    }
}

private struct PreviewRenderer: TextRenderer {
    /// The clock of this frame.
    var now: Date
    /// When each leaving glyph (in order) went into the field; glyphs past the end have not.
    var exits: [Date]
    var shimmers: Bool
    var lifts: Bool
    var scroll: ExitScroll
    /// Trailing glyphs not typed in yet (`PreviewReveal`): laid out, not drawn.
    var hidden = 0
    /// Lines drawn below the text's own bounds while it is moved down to the exit line (the row clips them).
    var displayPadding = EdgeInsets(top: 0, leading: 0, bottom: 600, trailing: 0)

    static let lift: CGFloat = 6
    static let fadeSeconds = 0.22
    static let shimmerPeriod = 3.2

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The exit point: the line of the next letter to leave (the last one that left, when all have). The window starts there,
        // so the leaving letters are always in view; with nothing leaving, or the text fitting two lines, it is the newest words.
        var exitLine: Int?
        var count = 0
        for (index, line) in layout.enumerated() {
            for run in line where run[PreviewRole.self] == .leaving {
                for _ in run {
                    if count <= exits.count { exitLine = index }
                    count += 1
                }
            }
        }
        let lines = Array(layout)
        var shift = 0.0
        if let exitLine { shift = Double(max(0, lines.count - 2 - min(exitLine, max(0, lines.count - 2)))) }
        let animated = scroll.value(toward: shift, at: now)
        if animated != 0, lines.count > 1 {
            context.translateBy(x: 0, y: CGFloat(animated) * (lines[1].origin.y - lines[0].origin.y))
        }
        var glyph = 0
        var waiting: [Text.Layout.RunSlice] = []
        let total = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        let visible = total - hidden
        var position = 0
        func drawPlain(_ run: Text.Layout.Run, in context: inout GraphicsContext) -> [Text.Layout.RunSlice] {
            guard hidden > 0 else { position += run.count; context.draw(run); return Array(run) }
            var shown: [Text.Layout.RunSlice] = []
            for slice in run {
                if position < visible { context.draw(slice); shown.append(slice) }
                position += 1
            }
            return shown
        }
        for line in layout {
            for run in line {
                switch run[PreviewRole.self] {
                case .leaving?:
                    position += run.count
                    for slice in run {
                        let progress = glyph < exits.count ? min(1, max(0, now.timeIntervalSince(exits[glyph]) / Self.fadeSeconds)) : 0
                        glyph += 1
                        guard progress < 1 else { continue }
                        var copy = context
                        copy.opacity = 1 - progress
                        if lifts { copy.translateBy(x: 0, y: -Self.lift * CGFloat(1 - (1 - progress) * (1 - progress))) }
                        copy.draw(slice)
                    }
                case .waiting?:
                    let shown = drawPlain(run, in: &context)
                    if shimmers { waiting.append(contentsOf: shown) }
                case nil:
                    _ = drawPlain(run, in: &context)
                }
            }
        }
        guard !waiting.isEmpty else { return }
        // The waiting glyphs once more, filled with a magic gradient that drifts across the row.
        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.shimmerPeriod) / Self.shimmerPeriod
        var overlay = context
        overlay.opacity = 0.6
        overlay.clipToLayer { mask in for slice in waiting { mask.draw(slice) } }
        let width = max(bounds.width, 1)
        overlay.fill(Path(bounds), with: .linearGradient(Gradient(colors: MagicGradient.colors),
                                                         startPoint: CGPoint(x: bounds.minX - width + 2 * width * phase, y: bounds.midY),
                                                         endPoint: CGPoint(x: bounds.minX + 2 * width * phase, y: bounds.midY)))
    }
}

/// The dictation preview text: a clearly readable secondary colour, one line centred vertically, two lines filling the row, and
/// a soft fade at the first line's leading edge when the head of the text is cut off. While a staged take shows it: the unit
/// being typed leaves letter by letter, words waiting for cleanup shimmer, and a tap (which sends them) blooms from the
/// touch point (`canSend`; a tap on nothing to send does nothing). A swipe up sends the words as spoken, and the text swooshes
/// up once (no colours, no bloom; none with Reduce Motion).
private struct PreviewRow: View {
    let text: String
    let layout: StagedDictation.PreviewLayout?
    let canSend: Bool
    /// A tap that sends, at the touch point (the row's own coordinates).
    let onSend: (CGPoint) -> Void
    /// A swipe up: send without cleanup.
    let onSendRaw: () -> Void
    /// Whether the current drag already sent; resets when the drag ends or is cancelled (iOS may cancel an upward touch at once).
    @GestureState private var swipeFired = false
    /// The swoosh: the text lifts and dims a little, then settles back.
    @State private var swoosh = false
    @State private var scroll = ExitScroll()
    @State private var reveal = PreviewReveal()
    /// Flips when a reveal finishes, so the timeline pauses again.
    @State private var revealSettled = false
    @State private var textHeight = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When each letter of the leaving unit went into the field (`PreviewRenderer.exits`).
    @State private var exits: [Date] = []
    /// The unit that just left, so the rest can settle into its place.
    @State private var lastLeaving = ""
    @State private var settleOffset: CGFloat = 0

    private var leavingText: String {
        guard let layout else { return "" }
        return String(Array(layout.text)[layout.leaving.clamped(to: 0..<layout.text.count)])
    }
    private var exited: Int { layout?.exited ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let height = Double(proxy.size.height)
            let size = WordRowHeight.previewFontSize(rowHeight: height)
            let single = WordRowHeight.previewIsSingleLine(textHeight: textHeight, size: size)
            let truncated = WordRowHeight.previewTruncated(textHeight: textHeight, rowHeight: height, prefixed: text.hasPrefix("…")) && (layout?.leaving.isEmpty ?? true)
            let _ = revealSettled
            let _ = reveal.update(text: text, placeholder: KeyboardController.listening, enabled: !reduceMotion)
            let animating = exits.contains { Date().timeIntervalSince($0) < PreviewRenderer.fadeSeconds + 0.1 } || reveal.hidden > 0
            let shimmers = !reduceMotion && !(layout?.waiting.isEmpty ?? true)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating && !shimmers)) { timeline in
                let hadHidden = reveal.hidden > 0
                let settled = reveal.advance(now: timeline.date, total: text.count)
                let _ = { if hadHidden && settled { Task { @MainActor in revealSettled.toggle() } } }()
                composed
                    .font(.system(size: CGFloat(size)))
                    .lineSpacing(CGFloat(WordRowHeight.previewLineSpacing(size: size)))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.leading)
                    .textRenderer(PreviewRenderer(now: timeline.date, exits: exits, shimmers: shimmers, lifts: !reduceMotion, scroll: scroll, hidden: reveal.hidden))
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { textHeight = $0 }
            .offset(x: settleOffset, y: swoosh ? -Self.swooshLift : 0)
            .opacity(swoosh ? 0.55 : 1)
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
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                guard canSend else { return }
                onSend(point)
            }
            // A drag never also taps: the tap fails once the finger has moved. It fires while moving, once per drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.swipeDistance, coordinateSpace: .local)
                    .updating($swipeFired) { value, fired, _ in
                        guard !fired, canSend else { return }
                        let dx = value.translation.width, dy = value.translation.height
                        guard dy <= -Self.swipeDistance, abs(dy) > 2 * abs(dx) else { return }
                        fired = true
                        Task { @MainActor in
                            onSendRaw()
                            playSwoosh()
                        }
                    })
            .onChange(of: exited) { old, new in
                if new > old { exits.append(contentsOf: Array(repeating: Date(), count: new - old)) } else { exits = [] }
            }
            .onChange(of: leavingText) { old, new in
                if new.isEmpty {
                    exits = []
                    settle(after: old, fontSize: CGFloat(size), width: proxy.size.width)
                }
            }
        }
    }

    /// The text with its roles marked (`PreviewRole`); a plain text when no staged take owns it.
    private var composed: Text {
        let prefix = text.hasPrefix("…") ? "…" : ""
        guard let layout, layout.text == String(text.dropFirst(prefix.count)) else { return Text(text) }
        let body = Array(layout.text)
        var roles = [PreviewRole?](repeating: nil, count: body.count)
        for range in layout.waiting { for index in range.clamped(to: 0..<body.count) { roles[index] = .waiting } }
        for index in layout.leaving.clamped(to: 0..<body.count) { roles[index] = .leaving }
        var result = Text(prefix)
        var start = 0
        while start < body.count {
            var end = start + 1
            while end < body.count, roles[end] == roles[start] { end += 1 }
            var piece = Text(String(body[start..<end]))
            if let role = roles[start] { piece = piece.customAttribute(role) }
            result = Text("\(result)\(piece)")
            start = end
        }
        return result
    }

    /// The least upward travel, in points, that is a swipe (an estimate to tune on the phone).
    private static let swipeDistance: CGFloat = 20
    private static let swooshLift: CGFloat = 10

    /// A brief upward lift of the text, dimmed, then back; the letters leave as they type, as for a tap. Reduce Motion: none.
    private func playSwoosh() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.12)) { swoosh = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeIn(duration: 0.2)) { swoosh = false }
        }
    }

    /// The unit has left: the rest was laid out behind it and now starts where the unit did, so it slides from where it stood
    /// (a short move; the distance is the unit's width, at most `maxSettle`, an estimate). Reduce Motion: no move.
    private static let maxSettle: CGFloat = 48
    private func settle(after unit: String, fontSize: CGFloat, width: CGFloat) {
        guard !reduceMotion, !unit.isEmpty else { return }
        let measured = unit.size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize)]).width
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) { settleOffset = min(Self.maxSettle, measured) }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.22)) { settleOffset = 0 }
        }
    }
}
