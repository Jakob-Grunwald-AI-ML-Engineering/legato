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
            PreviewRow(text: text, instruction: instruction, layout: controller.dictationPreviewLayout, draft: draft,
                       canSend: controller.canSendPreview,
                       canDiscard: controller.canDiscardPreview, insets: Self.textInsets(keySide: keySide), bandHeight: bandHeight, reservesChip: showsUndo,
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
                .accessibilityAction(named: draft == nil ? "Insert without cleanup" : "Insert draft") { if controller.canSendPreview { controller.previewSwiped() } }
                .accessibilityAction(named: "Clear") { if controller.canDiscardPreview { controller.discardPreview() } }
                .accessibilityIdentifier("keyboard.hint")
            if showsUndo { undoChip.transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Self.fadeSeconds), value: showsUndo)
        .background { magicBackground }
        .task(id: bloom?.start) {
            guard let start = bloom?.start else { return }
            try? await Task.sleep(for: .seconds(Self.bloomSeconds))
            if !Task.isCancelled, bloom?.start == start { bloom = nil }
        }
        .onDisappear { controller.endPreviewHold(apply: false) }
    }

    nonisolated static let fadeSeconds = 0.15
    private static let bloomSeconds = 0.35

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
                listeningGlow.transition(.opacity)
            }
            if let bloom {
                TimelineView(.animation) { timeline in
                    let duration = reduceMotion ? 0.2 : Self.bloomSeconds
                    let age = timeline.date.timeIntervalSince(bloom.start)
                    let progress = min(1, max(0, age / duration))
                    Canvas { context, size in
                        let bounds = Path(CGRect(origin: .zero, size: size))
                        if reduceMotion {
                            context.fill(bounds, with: .color(.primary.opacity(0.1 * (1 - progress))))
                        } else {
                            let remaining = 1 - progress
                            let reach = hypot(max(bloom.point.x, size.width - bloom.point.x),
                                              max(bloom.point.y, size.height - bloom.point.y))
                            let radius = max(1, reach * (1 - remaining * remaining))
                            let colors = MagicGradient.colors.map { $0.opacity(0.4 * remaining * remaining) }
                            context.fill(bounds, with: .radialGradient(Gradient(colors: colors + [.clear]),
                                                                      center: bloom.point, startRadius: 0, endRadius: radius))
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: WordRowLayout.contentInset))
        .animation(reduceMotion ? nil : .smooth, value: listening)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var listeningGlow: some View {
        if reduceMotion {
            Color.primary.opacity(0.08)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let origin = glowOrigin ?? CGPoint(x: size.width / 2, y: size.height / 2)
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / PreviewRenderer.shimmerPeriod
                    let center = CGPoint(x: origin.x * 0.4 + size.width * (0.3 + 0.16 * sin(phase)),
                                         y: size.height * (0.5 + 0.2 * cos(phase)))
                    let colors = MagicGradient.colors.map { $0.opacity(0.16) }
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .radialGradient(Gradient(colors: colors + [.clear]), center: center,
                                                       startRadius: 0, endRadius: max(1, size.width * 0.75)))
                }
            }
        }
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
            guard let controller, controller.canComposePreview else { return }
            onBloom(coordinates.convert(globalPoint: point))
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
    var glyphs: [CGRect] = []
}

/// A single cleanup result. Keep the shared grapheme diff for small changes, and poof as a group
/// when most of the draft is new or the diff would be too costly to run on the keyboard's main thread.
private struct PreviewRewrite: Equatable {
    let original: String
    let target: String
    let removed: Set<Int>
    let inserted: Set<Int>
    let survivors: [Int: Int]
    let start: Date
    var duration: Double { PreviewRenderer.fadeSeconds / 2 + ChunkEntrance.capMs / 1000 + DictationPreviewView.fadeSeconds }
    var delayPerPiece: Double { ChunkEntrance.gapMs / 1000 }
    var glyphsPerPiece: Int { max(1, (inserted.count + pieceLimit - 1) / pieceLimit) }
    private var pieceLimit: Int { Int(ChunkEntrance.capMs / ChunkEntrance.gapMs) + 1 }

    init(original: String, target: String, start: Date) {
        self.original = original
        self.target = target
        self.start = start
        let before = Array(original), after = Array(target)
        if before.count <= 600, after.count <= 600 {
            let changes = ShadowEditPlanner.changes(from: before, to: after)
            var removed: Set<Int> = [], inserted: Set<Int> = []
            var shift = 0
            for change in changes {
                removed.formUnion(change.start..<change.end)
                let next = change.start + shift
                inserted.formUnion(next..<(next + change.text.count))
                shift += change.text.count - (change.end - change.start)
            }
            let kept = before.count - removed.count
            if kept * 2 >= max(before.count, after.count) {
                self.removed = removed
                self.inserted = inserted
                survivors = Dictionary(uniqueKeysWithValues: zip(after.indices.filter { !inserted.contains($0) },
                                                                  before.indices.filter { !removed.contains($0) }))
                return
            }
        }
        removed = Set(before.indices)
        inserted = Set(after.indices)
        survivors = [:]
    }
}

/// The plain typewriter reveal of words entering the preview: how many trailing characters of the text are still hidden. Growth
/// (new words appended, the head possibly cut off at the front) types in at `TypewriterDrain`'s pace; any other change shows at
/// once. No colour: revealed glyphs are drawn like all the rest. Drawing keeps this clock.
private final class PreviewReveal {
    private var text = ""
    private var last = Date.distantPast
    private(set) var hidden = 0

    private static func body(_ text: String) -> String { text.hasPrefix("…") ? String(text.dropFirst()) : text }

    /// The text of this frame: what it adds to the previous one is hidden from the end. A `placeholder` is not words: it shows at
    /// once and the first words after it type in from nothing.
    func update(text newText: String, placeholders: [String], enabled: Bool) {
        guard newText != text else { return }
        let old = placeholders.contains(text) ? "" : text
        defer { text = newText }
        let new = Self.body(newText), prior = Self.body(old)
        guard enabled, !placeholders.contains(newText), !new.isEmpty else { hidden = 0; return }
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
    var reference: ExitProbe? = nil
    var capturesReference = false
    /// Trailing glyphs not typed in yet (`PreviewReveal`): laid out, not drawn.
    var hidden = 0
    /// Room above the text for the leaving letters' lift (the scroll view clips the rest).
    var displayPadding = EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0)

    static let lift: CGFloat = 6
    static let fadeSeconds = 0.22
    static let shimmerPeriod = 3.2

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The exit line: the line of the next letter to leave (the last one that left, when all have), reported to the scroll view.
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
        probe.line = exitLine.map { (lines[$0].typographicBounds.rect.minY, lines[$0].typographicBounds.rect.maxY) }
        var glyph = 0
        var entrance = 0
        var glyphRects: [CGRect] = []
        var waiting: [Text.Layout.RunSlice] = []
        let total = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        let visible = total - hidden
        var position = 0
        let elapsed = rewrite.map { now.timeIntervalSince($0.start) } ?? 0
        let poof = min(1, max(0, elapsed / Self.fadeSeconds))
        let entranceGap = rewrite?.delayPerPiece ?? 0
        let glyphsPerPiece = rewrite?.glyphsPerPiece ?? 1
        func drawPlain(_ run: Text.Layout.Run, in context: inout GraphicsContext) -> [Text.Layout.RunSlice] {
            guard hidden > 0 || reference != nil else { position += run.count; context.draw(run); return Array(run) }
            var shown: [Text.Layout.RunSlice] = []
            for slice in run {
                if position < visible {
                    var copy = context
                    if let reference, let oldIndex = rewrite?.survivors[position], reference.glyphs.indices.contains(oldIndex) {
                        let old = reference.glyphs[oldIndex], current = slice.typographicBounds.rect
                        let oldBottom = reference.glyphs.last?.maxY ?? old.maxY
                        let newBottom = lines.last?.typographicBounds.rect.maxY ?? current.maxY
                        let remainder = CGFloat((1 - poof) * (1 - poof))
                        copy.translateBy(x: (old.minX - current.minX) * remainder,
                                         y: (old.minY - oldBottom - current.minY + newBottom) * remainder)
                    }
                    copy.draw(slice)
                    shown.append(slice)
                }
                position += 1
            }
            return shown
        }
        for line in layout {
            for run in line {
                if capturesReference { glyphRects.append(contentsOf: run.map { $0.typographicBounds.rect }) }
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
                case .poof?:
                    position += run.count
                    guard poof < 1 else { continue }
                    var copy = context
                    copy.translateBy(x: 0, y: -Self.lift * CGFloat(poof))
                    copy.opacity = 1 - poof
                    copy.addFilter(.blur(radius: 4 * poof))
                    copy.draw(run)
                case .entering?:
                    for slice in run {
                        position += 1
                        let delay = Double(entrance / glyphsPerPiece) * entranceGap
                        entrance += 1
                        let reveal = min(1, max(0, (elapsed - Self.fadeSeconds / 2 - delay) / DictationPreviewView.fadeSeconds))
                        guard reveal > 0 else { continue }
                        var copy = context
                        copy.opacity = reveal
                        copy.translateBy(x: 0, y: Self.lift * CGFloat(1 - reveal))
                        copy.draw(slice)
                    }
                case .hidden?:
                    position += run.count
                case nil:
                    _ = drawPlain(run, in: &context)
                }
            }
        }
        if capturesReference { probe.glyphs = glyphRects }
        guard !waiting.isEmpty else { return }
        // The waiting glyphs once more, filled with a magic gradient that drifts across the text.
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

/// The dictation preview text in a vertical scroll view without a scrollbar: a clearly readable secondary colour, bottom
/// anchored (a short text sits at the bottom, a long one shows its newest lines and follows as it grows). Scrolled up into older
/// text it stops following and resumes at the bottom or after `PreviewScroll.idleResumeSeconds`; a soft fade marks older text above.
/// While a staged take shows it: the unit being typed leaves letter by letter (the view keeps that line in view), words waiting
/// for cleanup shimmer. Holding captures Magic instructions. A swipe right sends the draft with a swoosh; a swipe left
/// clears the preview. Reduce Motion skips the motion effects.
private struct PreviewRow: View {
    let text: String
    let instruction: String
    let layout: StagedDictation.PreviewLayout?
    let draft: StagedDictation.PreviewDraft?
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
    @State private var rewriteReference = ExitProbe()
    @State private var rewrite: PreviewRewrite?
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
            ScrollView(.vertical) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating && !shimmers)) { timeline in
                    let hadHidden = reveal.hidden > 0
                    let settled = reveal.advance(now: timeline.date, total: visibleText.count)
                    let _ = { if hadHidden && settled { Task { @MainActor in revealSettled.toggle() } } }()
                    ZStack(alignment: .bottomLeading) {
                        if let transition, !transition.removed.isEmpty || !transition.survivors.isEmpty {
                            let originalDisplay = transition.original + text.dropFirst(transition.target.count)
                            styled(marked(originalDisplay) { transition.removed.contains($0) ? .poof : .hidden }, size: size)
                                .textRenderer(PreviewRenderer(now: timeline.date, exits: [], shimmers: false, lifts: true,
                                                              probe: rewriteReference, rewrite: transition, capturesReference: true))
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                        let body = styled(transition.map { change in marked(text) { change.inserted.contains($0) ? .entering : nil } } ?? composed, size: size)
                        let directions = Text(verbatim: instructionSuffix)
                            .font(.system(size: CGFloat(size)))
                            .foregroundStyle(Color(uiColor: .systemPurple))
                        Text("\(body)\(directions)")
                            .textRenderer(PreviewRenderer(now: timeline.date, exits: exits, shimmers: shimmers, lifts: !reduceMotion,
                                                          probe: probe, rewrite: transition,
                                                          reference: transition == nil ? nil : rewriteReference, hidden: reveal.hidden))
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
                                onSendRaw()
                                playSwoosh()
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
                guard let draft, draft.original != draft.text, !reduceMotion else { rewrite = nil; return }
                rewriteReference.glyphs = []
                let transition = PreviewRewrite(original: draft.original, target: draft.text, start: Date())
                rewrite = transition
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(transition.duration))
                    if rewrite?.start == transition.start { rewrite = nil }
                }
            }
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
        return Text("\(Text(prefix))\(marked(layout.text) { roles[$0] })")
    }

    private func styled(_ text: Text, size: Double) -> Text {
        text.font(.system(size: CGFloat(size)))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
    }

    private func marked(_ text: String, role: (Int) -> PreviewRole?) -> Text {
        let body = Array(text)
        let roles = body.indices.map(role)
        var result = Text("")
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
