import LegatoComposerUI
import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The dictation preview in its own frame (`TopRowLayout.preview`, taller than the transcript band): the words not in the field
/// yet, scrollable with no scrollbar and anchored on the newest words, with the Magic glow and the undo chip over it.
/// Tap to clean up, press to speak composition instructions, swipe right to insert, or swipe left to clear.
struct DictationPreviewView: View {
    let controller: KeyboardController
    let text: String
    /// The dictation key's side: the text keeps the key's inset there and the rounded corner's on the other side.
    let keySide: DictationKeySide
    /// The transcript band's height: the type size is the largest that fits two lines in it (`WordRowHeight`), so it does not
    /// grow with the taller preview; more lines show instead.
    let bandHeight: Double

    @State private var bloom: (point: CGPoint, start: Date)?
    @State private var glowOrigin: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate static func textInsets(keySide: DictationKeySide) -> EdgeInsets {
        let i = WordRowLayout.insets(keySide: keySide)
        return EdgeInsets(top: 0, leading: CGFloat(i.leading), bottom: 0, trailing: CGFloat(i.trailing))
    }

    var body: some View {
        let showsUndo = controller.canUndoDiscard
        let draft = controller.composedPreview
        let instruction = controller.previewInstructionText
        ZStack(alignment: keySide == .right ? .bottomTrailing : .bottomLeading) {
            PreviewRow(controller: controller, text: text, instruction: instruction, layout: controller.dictationPreviewLayout, draft: draft,
                       canSend: controller.previewOffersSend,
                       canDiscard: controller.previewOffersDiscard, insets: Self.textInsets(keySide: keySide), bandHeight: bandHeight, reservesChip: showsUndo,
                       hold: PreviewHoldGesture(controller: controller, onBloom: showBloom),
                       onSendRaw: { controller.previewSwiped() },
                       onDiscard: { controller.discardPreview() })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(draft == nil ? text : "Dictation draft")
                .accessibilityValue(instruction.isEmpty ? (draft == nil ? "" : text) :
                                    (draft == nil ? instruction : "\(text). \(instruction)"))
                .accessibilityHint(controller.canComposePreview ? "Tap to clean up. Press to speak Magic instructions. Swipe right to insert, left to clear." : draft != nil ? "Swipe right to insert, left to clear." : "")
                .accessibilityAddTraits(controller.canComposePreview ? .isButton : [])
                .accessibilityAction(named: "Compose draft") { controller.composePreviewWithoutInstructions() }
                .accessibilityAction(named: draft == nil ? "Insert without cleanup" : "Insert draft") { if controller.previewOffersSend { controller.previewSwiped() } }
                .accessibilityAction(named: "Clear") { if controller.previewOffersDiscard { controller.discardPreview() } }
                .accessibilityIdentifier("keyboard.hint")
            if showsUndo { undoChip.transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Self.fadeSeconds), value: showsUndo)
        .background { magicBackground }
        .task(id: bloom?.start) {
            guard let start = bloom?.start else { return }
            try? await Task.sleep(for: .seconds(MagicPreviewRipple.seconds))
            if !Task.isCancelled, bloom?.start == start { bloom = nil }
        }
        .onDisappear { controller.endPreviewHold(apply: false) }
    }

    nonisolated static let fadeSeconds = 0.15

    /// "Undo" while the app keeps the cleared words (`KeyboardController.canUndoDiscard`), on the dictation key's side.
    private var undoChip: some View {
        Button { controller.undoDiscard() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                .padding(.horizontal, 12)
                .frame(height: CGFloat(PreviewScroll.undoChipHeight))
                .background(Color(uiColor: KeyColors.suggestion).opacity(0.15), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .padding(keySide == .right ? .trailing : .leading, CGFloat(WordRowLayout.contentInset))
        .accessibilityLabel("Undo clear")
        .accessibilityIdentifier("keyboard.preview.undo")
    }

    private func showBloom(at point: CGPoint) {
        glowOrigin = point
        bloom = (point, Date())
    }

    private var magicBackground: some View {
        let listening = controller.isPreviewInstructionReady
        return ZStack {
            // Keep the background's frame while the listening glow fades out.
            Color.clear
            if listening {
                MagicPreviewGlow(origin: glowOrigin).transition(.opacity)
            }
            if let bloom { MagicPreviewRipple(start: bloom.start, origin: bloom.point) }
        }
        .clipShape(RoundedRectangle(cornerRadius: WordRowLayout.contentInset))
        .animation(reduceMotion ? nil : .smooth, value: listening)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A single recognizer distinguishes a tap from a press. Native movement cancellation lets
/// a scrolling or swiping finger leave before the press is recognized.
private struct PreviewHoldGesture: UIGestureRecognizerRepresentable {
    let controller: KeyboardController
    let onBloom: (CGPoint) -> Void

    final class Recognizer: UILongPressGestureRecognizer {
        var tapped: ((CGPoint) -> Void)?
        private var tapOrigin: CGPoint?
        private(set) var moved = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if tapOrigin == nil, touches.count == 1 { tapOrigin = touches.first?.location(in: nil) }
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first, exceededTapTravel(touch) { moved = true }
            super.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first, exceededTapTravel(touch) { moved = true }
            let wasTap = state == .possible && !moved && touches.count == 1 && numberOfTouches == 1
            let point = touches.first?.location(in: nil)
            super.touchesEnded(touches, with: event)
            if wasTap, let point { tapped?(point) }
        }

        override func reset() {
            super.reset()
            tapOrigin = nil
            moved = false
        }

        /// A press that began never keeps the preview's scroll view from scrolling: a finger that rests a moment before it drags
        /// scrolls, and the move ends the press (`moved`).
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            preventedGestureRecognizer is UIPanGestureRecognizer ? false : super.canPrevent(preventedGestureRecognizer)
        }

        private func exceededTapTravel(_ touch: UITouch) -> Bool {
            guard let tapOrigin else { return true }
            let point = touch.location(in: nil)
            return hypot(point.x - tapOrigin.x, point.y - tapOrigin.y) > allowableMovement
        }
    }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        // A short grace period distinguishes a quick tap from a deliberate press.
        recognizer.minimumPressDuration = 0.12
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        let coordinates = context.converter
        recognizer.tapped = { [weak controller, onBloom] point in
            guard let controller, controller.previewOffersCompose else { return }
            // Without Full Access the tap only says how to turn it on (`KeyboardController.needsFullAccess`): no bloom.
            if controller.canComposePreview { onBloom(coordinates.convert(globalPoint: point)) }
            controller.composePreviewWithoutInstructions()
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        switch recognizer.state {
        case .began where !recognizer.moved:
            if controller.beginPreviewHold() { onBloom(context.converter.localLocation) }
        case .changed where recognizer.moved: controller.endPreviewHold(apply: false)
        case .ended: controller.endPreviewHold(apply: !recognizer.moved)
        case .cancelled: controller.endPreviewHold(apply: false)
        default: break
        }
    }
}

/// How a run of the preview text is drawn (`PreviewRenderer`): the unit being typed into the field, or closed words waiting
/// for their cleanup.
private enum PreviewRole: TextAttribute, Equatable { case leaving, waiting, entering, poof, hidden }

/// Where the line the next letter leaves from sits in the laid-out text (the renderer writes it while drawing), so the scroll
/// view can keep it in view. Drawing keeps this, like `PreviewReveal`.
private final class ExitProbe {
    /// The line's top and bottom in the text's own coordinates; nil while nothing leaves.
    var line: (minY: CGFloat, maxY: CGFloat)?
}

/// What the renderer last drew, for the blank-preview check (`PreviewRow.checkBlank`, internal builds): which text, how many
/// glyphs it laid out and drew, and where they sit. Drawing writes it, like `ExitProbe`.
private final class PreviewDrawProbe {
    var draws = 0
    var lastDrawAt: Date?
    /// The `generation` of the text last drawn (`PreviewRenderer.generation`).
    var generation: Int?
    var laidOut = 0
    var drawn = 0
    var bounds: CGRect?
}

private final class RewriteReference {
    var glyphs: [Int: CGRect] = [:]
    var bottom: CGFloat?
}

/// A single cleanup result and the shared grapheme diff that drives its transition.
private struct PreviewRewrite: Equatable {
    let original: String
    let target: String
    private let diff: PreviewRewriteDiff
    var removed: Set<Int> { diff.removed }
    var inserted: Set<Int> { diff.inserted }
    var survivors: [Int: Int] { diff.survivors }
    let start: Date
    var duration: Double { PreviewRenderer.fadeSeconds / 2 + ChunkEntrance.capMs / 1000 + MagicPreviewEffects.entranceSeconds }
    var delayPerPiece: Double { ChunkEntrance.gapMs / 1000 }
    var glyphsPerPiece: Int { max(1, (inserted.count + pieceLimit - 1) / pieceLimit) }
    private var pieceLimit: Int { Int(ChunkEntrance.capMs / ChunkEntrance.gapMs) + 1 }

    init(original: String, target: String, start: Date) {
        self.original = original
        self.target = target
        self.start = start
        diff = PreviewRewriteDiff(original: original, target: target)
    }
}

/// The plain typewriter reveal of words entering the preview: how many trailing characters of the text are still hidden. Growth
/// (new words appended, the head possibly cut off at the front) types in at `TypewriterDrain`'s pace; any other change shows at
/// once. No colour: revealed glyphs are drawn like all the rest. Drawing keeps this clock.
private final class PreviewReveal {
    private var text = ""
    private var last = Date.distantPast
    private(set) var hidden = 0

    /// At most this many trailing characters type in. A larger growth (a long speech update at once, #336) shows at once except
    /// its last ones: the preview follows its newest lines, which must never be letters it has not drawn yet. About a line of the
    /// preview at its type size (an estimate); a spoken word or two arrives well under it.
    static let maxHidden = 40

    private static func body(_ text: String) -> String { text.hasPrefix("…") ? String(text.dropFirst()) : text }

    /// The text of this frame: what it adds to the previous one is hidden from the end. A `placeholder` is not words: it shows at
    /// once and the first words after it type in from nothing.
    func update(text newText: String, placeholders: [String], enabled: Bool) {
        guard newText != text else { return }
        let old = placeholders.contains(text) ? "" : text
        defer { text = newText }
        let new = Self.body(newText), prior = Self.body(old)
        guard enabled, !placeholders.contains(newText), !new.isEmpty else { hidden = 0; return }
        guard !prior.isEmpty else { hidden = min(new.count, Self.maxHidden); return }
        // The old text, minus a head the preview cut off, is the start of the new one.
        let oldChars = Array(prior), newChars = Array(new)
        for cut in 0..<oldChars.count where newChars.starts(with: oldChars[cut...]) {
            hidden = min(newChars.count, Self.maxHidden, hidden + newChars.count - (oldChars.count - cut))
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

/// Draws the preview with per-glyph effects, by role, and leaves every glyph in its place so nothing reflows:
/// - leaving glyphs lift `lift` and fade over `fadeSeconds` from their own exit time (the unit's letters, as the field types them);
/// - waiting glyphs (closed units whose cleanup has not landed: "thinking") carry a slow magic-coloured shimmer, the only use
///   of the magic colours here; words entering are plain (`hidden`: the glyphs not typed in yet are not drawn).
/// The lift, fade length and shimmer period are estimates, to tune on the phone.
private struct PreviewRenderer: TextRenderer {
    /// The clock of this frame.
    var now: Date
    /// When each leaving glyph (in order) went into the field; glyphs past the end have not.
    var exits: [Date]
    var shimmers: Bool
    var lifts: Bool
    var probe: ExitProbe
    var rewrite: PreviewRewrite? = nil
    var reference: RewriteReference? = nil
    var capturesReference = false
    var viewport: CGRect? = nil
    /// Trailing glyphs not typed in yet (`PreviewReveal`): laid out, not drawn.
    var hidden = 0
    /// Room above the text for the leaving letters' lift (the scroll view clips the rest).
    var displayPadding = EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0)
    /// Internal builds: where to note what was drawn, and which text it was.
    var drawProbe: PreviewDrawProbe? = nil
    var generation = 0

    static let lift = MagicPreviewEffects.lift
    static let fadeSeconds = MagicPreviewEffects.poofSeconds

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if !capturesReference { probe.line = nil }
        var glyph = 0
        var entrance = 0
        var glyphRects: [Int: CGRect] = [:]
        var waiting: [Text.Layout.RunSlice] = []
        let visible = hidden == 0 ? Int.max : layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } } - hidden
        var position = 0
        let elapsed = rewrite.map { now.timeIntervalSince($0.start) } ?? 0
        let poof = min(1, max(0, elapsed / Self.fadeSeconds))
        let entranceGap = rewrite?.delayPerPiece ?? 0
        let glyphsPerPiece = rewrite?.glyphsPerPiece ?? 1
        let effectBounds = viewport?.insetBy(dx: -MagicPreviewEffects.verticalEffectReach, dy: -MagicPreviewEffects.verticalEffectReach)
        let bottom = layout.last?.typographicBounds.rect.maxY
        var poofContext = context
        if capturesReference, let viewport { poofContext.clip(to: Path(viewport)) }
        var drawn = 0
        func drawPlain(_ run: Text.Layout.Run, trackSurvivors: Bool, shimmer: Bool, in context: inout GraphicsContext) {
            // A run wholly revealed draws as one, one wholly hidden not at all: only the run the reveal is in goes glyph by glyph,
            // so a long text costs a frame no more than a short one (#336).
            if !trackSurvivors, position + run.count <= visible {
                position += run.count
                drawn += run.count
                context.draw(run)
                if shimmer { waiting.append(contentsOf: run) }
                return
            }
            if !trackSurvivors, position >= visible {
                position += run.count
                return
            }
            for slice in run {
                if position < visible {
                    drawn += 1
                    if trackSurvivors, let reference, let oldIndex = rewrite?.survivors[position],
                       let old = reference.glyphs[oldIndex], let oldBottom = reference.bottom, let bottom {
                        MagicPreviewEffects.drawSurvivor(slice, from: old, verticalAdjustment: bottom - oldBottom,
                                                         progress: poof, in: context)
                    } else {
                        context.draw(slice)
                    }
                    if shimmer { waiting.append(slice) }
                }
                position += 1
            }
        }
        for line in layout {
            let bounds = line.typographicBounds.rect
            let animateLine = effectBounds?.intersects(bounds) == true
            for run in line {
                let role = run[PreviewRole.self]
                if capturesReference, animateLine, poof < 1 {
                    for (offset, slice) in run.enumerated() { glyphRects[position + offset] = slice.typographicBounds.rect }
                }
                switch role {
                case .leaving?:
                    if glyph <= exits.count { probe.line = (bounds.minY, bounds.maxY) }
                    position += run.count
                    guard animateLine else {
                        if glyph >= exits.count { context.draw(run); drawn += run.count }
                        glyph += run.count
                        continue
                    }
                    for slice in run {
                        let progress = glyph < exits.count ? min(1, max(0, now.timeIntervalSince(exits[glyph]) / Self.fadeSeconds)) : 0
                        glyph += 1
                        guard progress < 1 else { continue }
                        var copy = context
                        copy.opacity = 1 - progress
                        if lifts { copy.translateBy(x: 0, y: -Self.lift * CGFloat(1 - (1 - progress) * (1 - progress))) }
                        copy.draw(slice)
                        drawn += 1
                    }
                case .waiting?:
                    drawPlain(run, trackSurvivors: false, shimmer: shimmers && animateLine, in: &context)
                case .poof?:
                    position += run.count
                    if animateLine { MagicPreviewEffects.drawPoof(run, progress: poof, in: poofContext) }
                case .entering?:
                    guard animateLine else {
                        position += run.count
                        entrance += run.count
                        drawn += run.count
                        context.draw(run)
                        continue
                    }
                    for slice in run {
                        position += 1
                        drawn += 1
                        let delay = Double(entrance / glyphsPerPiece) * entranceGap
                        entrance += 1
                        let reveal = min(1, max(0, (elapsed - Self.fadeSeconds / 2 - delay) / MagicPreviewEffects.entranceSeconds))
                        MagicPreviewEffects.drawEntrance(slice, progress: reveal, in: context)
                    }
                case .hidden?:
                    position += run.count
                case nil:
                    drawPlain(run, trackSurvivors: animateLine && poof < 1 && reference?.bottom != nil,
                              shimmer: false, in: &context)
                }
            }
        }
        if capturesReference {
            reference?.glyphs = glyphRects
            reference?.bottom = bottom
        }
        MagicPreviewEffects.drawShimmer(waiting, in: layout, now: now, context: context, viewport: viewport)
        if let drawProbe {
            drawProbe.draws += 1
            drawProbe.lastDrawAt = Date()
            drawProbe.generation = generation
            drawProbe.laidOut = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
            drawProbe.drawn = drawn
            drawProbe.bounds = layout.reduce(nil as CGRect?) { bounds, line in
                bounds.map { $0.union(line.typographicBounds.rect) } ?? line.typographicBounds.rect
            }
        }
    }
}

/// The dictation preview text in a vertical scroll view without a scrollbar: a clearly readable secondary colour, bottom
/// anchored (a short text sits at the bottom, a long one shows its newest lines and follows as it grows). Scrolled up into older
/// text it stops following and resumes at the bottom or after `PreviewScroll.idleResumeSeconds`; a soft fade marks older text above.
/// While a staged take shows it: the unit being typed leaves letter by letter (the view keeps that line in view), words waiting
/// for cleanup shimmer. Holding captures Magic instructions. A swipe right sends the draft with a swoosh; a swipe left
/// clears the preview. Reduce Motion skips the motion effects.
private struct PreviewRow: View {
    let controller: KeyboardController
    let text: String
    let instruction: String
    let layout: StagedDictation.PreviewLayout?
    let draft: StagedDictation.PreviewDraft?
    /// The preview takes a swipe right or left (`KeyboardController.previewOffersSend`, `previewOffersDiscard`); without Full Access
    /// the swipe reaches the controller, which says how to turn it on.
    let canSend: Bool
    let canDiscard: Bool
    /// The text's leading and trailing insets (`WordRowLayout.insets`).
    let insets: EdgeInsets
    let bandHeight: Double
    /// The undo chip is up: the text keeps clear of it at the bottom.
    let reservesChip: Bool
    let hold: PreviewHoldGesture
    /// A swipe right: send without cleanup.
    let onSendRaw: () -> Void
    /// A swipe left: clear what is still in the preview.
    let onDiscard: () -> Void

    /// Whether the current drag already acted. Resets when the drag ends or is cancelled (iOS may cancel a drag that leaves a
    /// short view).
    @GestureState private var fired = false
    /// The swoosh: the text slides right and dims a little, then settles back.
    @State private var swoosh = false
    @State private var reveal = PreviewReveal()
    @State private var probe = ExitProbe()
    @State private var rewriteReference = RewriteReference()
    @State private var rewrite: PreviewRewrite?
    @State private var rewriteDiagnostic: PreviewTransitionDiagnostic?
    @State private var originalViewport: CGRect?
    @State private var textViewport: CGRect?
    /// Flips when a reveal finishes, so the timeline pauses again.
    @State private var revealSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When each letter of the leaving unit went into the field (`PreviewRenderer.exits`).
    @State private var exits: [Date] = []
    @State private var settleOffset: CGFloat = 0
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = PreviewFollow()
    @State private var metrics = ScrollMetrics()
    @State private var scrollPhase = ScrollPhase.idle
    @State private var resumeTask: Task<Void, Never>?
    @State private var drawProbe = PreviewDrawProbe()
    @State private var previewFrame: CGRect?
    @State private var lastInkSample: Date?

    private struct ScrollMetrics: Equatable { var offset = 0.0, content = 0.0, container = 0.0 }
    private var scrollable: Bool { metrics.content > metrics.container + 0.5 }
    private var leaving: Bool { !(layout?.leaving.isEmpty ?? true) }
    private var userScrolling: Bool { scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating }

    private var leavingText: String {
        guard let layout else { return "" }
        return String(Array(layout.text)[layout.leaving.clamped(to: 0..<layout.text.count)])
    }
    private var exited: Int { layout?.exited ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let size = WordRowHeight.previewFontSize(rowHeight: bandHeight)
            let _ = revealSettled
            let instructionSuffix = instruction.isEmpty ? "" : " " + instruction
            let visibleText = text + instructionSuffix
            let _ = reveal.update(text: visibleText, placeholders: [KeyboardController.listening, KeyboardController.cleared],
                                  enabled: !reduceMotion && (draft == nil || !instruction.isEmpty))
            let transition = draft?.text == rewrite?.target && !reduceMotion && instruction.isEmpty ? rewrite : nil
            let animating = transition != nil || exits.contains { Date().timeIntervalSince($0) < PreviewRenderer.fadeSeconds + 0.1 } || reveal.hidden > 0
            let shimmers = !reduceMotion && !(layout?.waiting.isEmpty ?? true)
            let bottomPadding = reservesChip ? PreviewScroll.undoChipHeight + 4 : 2
            let original = transition.flatMap { change -> Text? in
                guard !change.removed.isEmpty || !change.survivors.isEmpty else { return nil }
                let originalDisplay = change.original + text.dropFirst(change.target.count)
                return styled(MagicPreviewEffects.marked(originalDisplay) { change.removed.contains($0) ? PreviewRole.poof : .hidden }, size: size)
            }
            let body = styled(transition.map { change in
                MagicPreviewEffects.marked(text) { change.inserted.contains($0) ? PreviewRole.entering : nil }
            } ?? composed, size: size)
            let directions = Text(verbatim: instructionSuffix)
                .font(.system(size: CGFloat(size)))
                .foregroundStyle(Color(uiColor: .systemPurple))
            ScrollView(.vertical) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating && !shimmers)) { timeline in
                    let hadHidden = reveal.hidden > 0
                    let settled = reveal.advance(now: timeline.date, total: visibleText.count)
                    let _ = { if hadHidden && settled { Task { @MainActor in revealSettled.toggle() } } }()
                    ZStack(alignment: .bottomLeading) {
                        if let original, let transition {
                            original
                                .textRenderer(PreviewRenderer(now: timeline.date, exits: [], shimmers: false, lifts: true, probe: probe,
                                                              rewrite: transition, reference: rewriteReference, capturesReference: true,
                                                              viewport: originalViewport))
                                .onGeometryChange(for: CGRect?.self) { $0.bounds(of: .scrollView(axis: .vertical)) } action: {
                                    originalViewport = $0
                                }
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                        Text("\(body)\(directions)")
                            .textRenderer(PreviewRenderer(now: timeline.date, exits: exits, shimmers: shimmers, lifts: !reduceMotion,
                                                          probe: probe, rewrite: transition,
                                                          reference: transition == nil ? nil : rewriteReference,
                                                          viewport: textViewport, hidden: reveal.hidden,
                                                          drawProbe: Self.checksBlank ? drawProbe : nil, generation: visibleText.hashValue))
                            .onGeometryChange(for: CGRect?.self) { $0.bounds(of: .scrollView(axis: .vertical)) } action: {
                                textViewport = $0
                            }
                            .task(id: transition?.start) {
                                guard transition != nil, let rewriteDiagnostic else { return }
                                controller.previewTransitionMounted(rewriteDiagnostic)
                            }
                    }
                    .lineSpacing(CGFloat(WordRowHeight.previewLineSpacing(size: size)))
                    .multilineTextAlignment(.leading)
                }
                .offset(x: settleOffset + (swoosh ? Self.swooshSlide : 0))
                .opacity(swoosh ? 0.55 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .padding(.top, CGFloat(PreviewScroll.topPadding))
                .padding(.bottom, CGFloat(bottomPadding))
                // A short text sits at the bottom; a long one is taller and scrolls.
                .frame(minHeight: proxy.size.height, alignment: .bottomLeading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offset: geometry.contentOffset.y, content: geometry.contentSize.height, container: geometry.containerSize.height)
            } action: { old, new in
                metrics = new
                scrollChanged(from: old, to: new)
            }
            .onScrollPhaseChange { _, new in scrollPhase = new }
            .mask {
                VStack(spacing: 0) {
                    // Soft top edge while older text is above.
                    LinearGradient(colors: [metrics.offset > 1 ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: CGFloat(PreviewScroll.topFadeHeight))
                    Color.black
                }
            }
            // Fully clear areas get no touches in a keyboard extension.
            .background(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(hold)
            // Act while moving, once per drag: a drag that
            // leaves a short view gets cancelled, so waiting for its end would lose it. Vertical drags still scroll.
            .simultaneousGesture(
                DragGesture(minimumDistance: CGFloat(PreviewScroll.swipeDistance), coordinateSpace: .local)
                    .updating($fired) { value, fired, _ in
                        guard !fired else { return }
                        switch PreviewScroll.swipe(dx: Double(value.translation.width), dy: Double(value.translation.height)) {
                        case .sendRaw? where canSend:
                            fired = true
                            Task { @MainActor in
                                // Without Full Access the swipe only says how to turn it on: no swoosh.
                                let sends = controller.canSendPreview
                                onSendRaw()
                                if sends { playSwoosh() }
                            }
                        case .clear? where canDiscard:
                            fired = true
                            Task { @MainActor in
                                onDiscard()
                            }
                        default: break
                        }
                    })
            .onChange(of: exited) { old, new in
                if new > old { exits.append(contentsOf: Array(repeating: Date(), count: new - old)) } else { exits = [] }
                keepExitInView()
            }
            .onChange(of: draft) { _, draft in
                finishRewrite(.cancelled)
                guard let draft else { return }
                rewriteDiagnostic = controller.beginPreviewTransition(draft)
                guard draft.original != draft.text else { finishRewrite(.unchanged); return }
                guard !reduceMotion else { finishRewrite(.reduceMotion); return }
                rewriteReference.glyphs = [:]
                rewriteReference.bottom = nil
                originalViewport = nil
                rewrite = PreviewRewrite(original: draft.original, target: draft.text, start: Date())
            }
            .task(id: rewrite?.start) {
                guard let transition = rewrite else { return }
                do { try await Task.sleep(for: .seconds(transition.duration)) }
                catch { return }
                if rewrite?.start == transition.start { finishRewrite(.completed) }
            }
            .onChange(of: reduceMotion) { _, reduced in if reduced { finishRewrite(.reduceMotion) } }
            .onChange(of: instruction.isEmpty) { _, empty in if !empty { finishRewrite(.cancelled) } }
            .onDisappear { finishRewrite(.cancelled) }
            #if DEBUG || LEGATO_INTERNAL
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previewFrame = $0 }
            .task(id: visibleText) { await checkBlank(visibleText) }
            #endif
            .onChange(of: leavingText) { old, new in
                if new.isEmpty {
                    exits = []
                    settle(after: old, fontSize: CGFloat(size), width: proxy.size.width)
                    // The exit is over: back to the newest words.
                    if follow.follows { position.scrollTo(edge: .bottom) }
                } else if old.isEmpty {
                    keepExitInView()
                }
            }
        }
    }

    // MARK: Blank check (#342)

    #if DEBUG || LEGATO_INTERNAL
    private static let checksBlank = true
    #else
    private static let checksBlank = false
    #endif
    /// How long the text holds still before the check: the typewriter reveal and a cleanup transition are over by then. An estimate.
    private static let blankCheckDelay = Duration.seconds(1)
    /// The pixel snapshot runs at most this often, and only when nothing cheaper names the cause. An estimate.
    private static let inkSampleInterval: TimeInterval = 5
    /// Less ink than this share of the preview's pixels counts as nothing drawn. An estimate: one short word covers about 1%.
    private static let minimumInk = 0.002

    #if DEBUG || LEGATO_INTERNAL
    /// Once the text has held still, the preview should show it (the "Listening…" placeholder included). When it evidently does
    /// not, the controller records `previewBlank` with what would name the cause next time.
    private func checkBlank(_ visible: String) async {
        let drawsAtChange = drawProbe.draws
        try? await Task.sleep(for: Self.blankCheckDelay)
        guard !Task.isCancelled, !visible.isEmpty, controller.isVisible, metrics.container > 0 else { return }
        var reasons: [PreviewDiagnostics.PreviewBlank.Reason] = []
        let drawnNow = drawProbe.generation == visible.hashValue
        if !drawnNow { reasons.append(.drawStall) }
        if drawnNow, drawProbe.laidOut > 0, drawProbe.drawn == 0 { reasons.append(.noGlyphs) }
        if let text = drawProbe.bounds, let viewport = textViewport, !viewport.intersects(text) { reasons.append(.offViewport) }
        let host = controller.hostViewState
        if let host, !host.inWindow || host.hidden || host.alpha < 0.01 || host.hostHidden == true || (host.hostAlpha ?? 1) < 0.01 {
            reasons.append(.detached)
        }
        var ink: Double?
        if reasons.isEmpty, let window = host?.window, let frame = previewFrame,
           lastInkSample.map({ Date().timeIntervalSince($0) >= Self.inkSampleInterval }) ?? true {
            lastInkSample = Date()
            ink = Self.inkShare(of: window, in: frame)
            if let ink, ink < Self.minimumInk { reasons.append(.noInk) }
        }
        guard !reasons.isEmpty else { return }
        let since = drawProbe.lastDrawAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        controller.recordPreviewBlank(.init(
            reasons: reasons, textCharacters: visible.count, revealHidden: reveal.hidden, draws: drawProbe.draws,
            drawsSinceChange: drawProbe.draws - drawsAtChange, msSinceDraw: since, laidOutGlyphs: drawProbe.laidOut,
            drawnGlyphs: drawProbe.drawn, textMinY: drawProbe.bounds.map { Double($0.minY) }, textMaxY: drawProbe.bounds.map { Double($0.maxY) },
            viewportMinY: textViewport.map { Double($0.minY) }, viewportMaxY: textViewport.map { Double($0.maxY) },
            scrollOffset: metrics.offset, contentHeight: metrics.content, containerHeight: metrics.container,
            inWindow: host?.inWindow, viewAlpha: host?.alpha, viewHidden: host?.hidden, hostAlpha: host?.hostAlpha,
            hostHidden: host?.hostHidden, ink: ink))
    }

    /// The share of pixels in `frame` (window coordinates) that differ from the most common one, from what is on screen. The
    /// preview's own background is clear or one glow colour, so text is most of what differs. One small snapshot at scale 1.
    private static func inkShare(of window: UIWindow, in frame: CGRect) -> Double? {
        let rect = frame.intersection(window.bounds)
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // 8 bits a channel, as read below: the default range is extended (16 bits a channel) on a wide-colour screen.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cg = image.cgImage, cg.bitsPerPixel == 32, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let width = cg.width, height = cg.height, stride = cg.bytesPerRow
        guard width > 0, height > 0 else { return nil }
        // Four bits a channel: anti-aliasing and the glow's gradient stay near the background's bucket.
        func bucket(_ p: UnsafePointer<UInt8>) -> Int { Int(p[0] >> 4) << 12 | Int(p[1] >> 4) << 8 | Int(p[2] >> 4) << 4 | Int(p[3] >> 4) }
        var counts = [Int: Int]()
        for y in 0..<height { for x in 0..<width { counts[bucket(bytes + y * stride + x * 4), default: 0] += 1 } }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        func far(_ a: Int, _ b: Int) -> Bool {
            (0..<4).contains { abs(((a >> ($0 * 4)) & 0xF) - ((b >> ($0 * 4)) & 0xF)) > 1 }
        }
        let inked = counts.reduce(0) { $0 + (far($1.key, background) ? $1.value : 0) }
        return Double(inked) / Double(width * height)
    }
    #endif

    private func finishRewrite(_ outcome: PreviewTransitionOutcome) {
        if let rewriteDiagnostic { controller.endPreviewTransition(rewriteDiagnostic, outcome: outcome) }
        rewriteDiagnostic = nil
        rewrite = nil
    }

    // MARK: Scrolling

    /// The content or the offset changed. Growth while following goes to the newest words (unless a unit is leaving: its line is
    /// kept in view instead); a scroll by the person updates whether to follow, and idle time hands following back.
    private func scrollChanged(from old: ScrollMetrics, to new: ScrollMetrics) {
        if new.content != old.content || new.container != old.container {
            if follow.follows, !leaving { position.scrollTo(edge: .bottom) }
            return
        }
        guard new.offset != old.offset, new.container > 0, userScrolling else { return }
        follow.scrolled(distanceFromBottom: new.content - new.offset - new.container)
        resumeTask?.cancel()
        guard !follow.follows else { return }
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PreviewScroll.idleResumeSeconds))
            guard !Task.isCancelled else { return }
            follow.idleElapsed()
            if reduceMotion { position.scrollTo(edge: .bottom) } else { withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) } }
        }
    }

    /// The line the next letter leaves from stays visible when the text is taller than the area: it scrolls to it (one line of
    /// the text above it stays in view). The person's own scrolling is left alone.
    private func keepExitInView() {
        guard follow.follows, scrollable, let line = probe.line else { return }
        let top = Double(line.minY) + PreviewScroll.topPadding, bottom = Double(line.maxY) + PreviewScroll.topPadding
        guard top < metrics.offset || bottom > metrics.offset + metrics.container else { return }
        position.scrollTo(y: max(0, top - (bottom - top)))
    }

    // MARK: Text

    /// The text with its roles marked (`PreviewRole`); a plain text when no staged take owns it.
    private var composed: Text {
        if draft != nil { return Text(text.isEmpty ? "\u{200B}" : text) }
        let prefix = text.hasPrefix("…") ? "…" : ""
        guard let layout, layout.text == String(text.dropFirst(prefix.count)) else { return Text(text) }
        let body = Array(layout.text)
        var roles = [PreviewRole?](repeating: nil, count: body.count)
        for range in layout.waiting { for index in range.clamped(to: 0..<body.count) { roles[index] = .waiting } }
        for index in layout.leaving.clamped(to: 0..<body.count) { roles[index] = .leaving }
        return Text("\(Text(prefix))\(MagicPreviewEffects.marked(layout.text) { roles[$0] })")
    }

    private func styled(_ text: Text, size: Double) -> Text {
        text.font(.system(size: CGFloat(size)))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
    }

    private static let swooshSlide: CGFloat = 10

    /// A brief slide of the text to the right, dimmed, then back; the letters leave as they type, as for a tap. Reduce Motion: none.
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

/// Lives above the top row so an exit can finish when the preview gives way to the word slots.
struct DictationPreviewExitView: View {
    let exit: KeyboardController.PreviewExit
    let keySide: DictationKeySide
    let bandHeight: Double
    let onFinished: () -> Void

    @State private var departing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = WordRowHeight.previewFontSize(rowHeight: bandHeight)
            let insets = DictationPreviewView.textInsets(keySide: keySide)
            let direction: CGFloat = exit.direction == .left ? -1 : 1
            Text(verbatim: exit.text)
                .font(.system(size: CGFloat(size)))
                .lineSpacing(CGFloat(WordRowHeight.previewLineSpacing(size: size)))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .padding(.bottom, exit.reservesUndo ? CGFloat(PreviewScroll.undoChipHeight + 4) : 2)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                .offset(x: departing ? direction * geometry.size.width : 0)
                .opacity(departing ? 0 : 1)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return onFinished() }
            withAnimation(.smooth(duration: DictationPreviewView.fadeSeconds), completionCriteria: .removed) {
                departing = true
            } completion: {
                onFinished()
            }
        }
    }
}
