import LegatoComposerUI
import LegatoKeyboardCore
import SwiftUI

/// The dictation preview in its own frame (`TopRowLayout.preview`, taller than the transcript band): the words not in the field
/// yet, scrollable with no scrollbar and anchored on the newest words, with the touch bloom and the undo chip over it.
/// Tap sends (cleaned), a swipe up at the bottom sends raw, a swipe left clears what is still in it (`PreviewScroll.swipe`).
struct DictationPreviewView: View {
    let controller: KeyboardController
    let text: String
    /// The dictation key's side: the text keeps the key's inset there and the rounded corner's on the other side.
    let keySide: DictationKeySide
    /// The transcript band's height: the type size is the largest that fits two lines in it (`WordRowHeight`), so it does not
    /// grow with the taller preview; more lines show instead.
    let bandHeight: Double

    /// The touch bloom across the preview, from the touch point (the preview's own coordinates).
    @State private var bloom: (point: CGPoint, start: Date)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var insets: EdgeInsets {
        let i = WordRowLayout.insets(keySide: keySide)
        return EdgeInsets(top: 0, leading: CGFloat(i.leading), bottom: 0, trailing: CGFloat(i.trailing))
    }

    var body: some View {
        let showsUndo = controller.canUndoDiscard
        ZStack(alignment: keySide == .right ? .bottomTrailing : .bottomLeading) {
            PreviewRow(text: text, layout: controller.dictationPreviewLayout, canSend: controller.canSendPreview,
                       canDiscard: controller.canDiscardPreview, insets: insets, bandHeight: bandHeight, reservesChip: showsUndo,
                       onSend: { point in bloom = (point, Date()); controller.previewTapped() },
                       onSendRaw: { controller.previewSwiped() },
                       onDiscard: { controller.discardPreview() })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityHint(controller.canSendPreview ? "Tap to send what you have said so far. Swipe left to clear." : "")
                .accessibilityAddTraits(controller.canSendPreview ? .isButton : [])
                .accessibilityAction { if controller.canSendPreview { controller.previewTapped() } }
                .accessibilityAction(named: "Insert without cleanup") { if controller.canSendPreview { controller.previewSwiped() } }
                .accessibilityAction(named: "Clear") { if controller.canDiscardPreview { controller.discardPreview() } }
                .accessibilityIdentifier("keyboard.hint")
            if showsUndo { undoChip.transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Self.fadeSeconds), value: showsUndo)
        .overlay { bloomOverlay }
        .onChange(of: bloom?.start) { _, start in
            guard let start else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(Self.bloomSeconds * 1000) + 100))
                if bloom?.start == start { bloom = nil }
            }
        }
    }

    static let fadeSeconds = 0.15
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

    /// A soft bloom of the magic colours growing from the touch point across the whole preview (350 ms, low opacity); with
    /// Reduce Motion a brief plain highlight.
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
}

/// How a run of the preview text is drawn (`PreviewRenderer`): the unit being typed into the field, or closed words waiting
/// for their cleanup.
private enum PreviewRole: TextAttribute { case leaving, waiting }

/// Where the line the next letter leaves from sits in the laid-out text (the renderer writes it while drawing), so the scroll
/// view can keep it in view. Drawing keeps this, like `PreviewReveal`.
private final class ExitProbe {
    /// The line's top and bottom in the text's own coordinates; nil while nothing leaves.
    var line: (minY: CGFloat, maxY: CGFloat)?
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
/// for cleanup shimmer, a tap sends them and blooms from the touch point (`canSend`), a swipe up at the bottom sends them as spoken
/// and the text swooshes up once, and a swipe left clears what is still in it (`canDiscard`; the text fades out). Reduce Motion: no
/// swoosh, fade, lift or shimmer.
private struct PreviewRow: View {
    let text: String
    let layout: StagedDictation.PreviewLayout?
    let canSend: Bool
    let canDiscard: Bool
    /// The text's leading and trailing insets (`WordRowLayout.insets`).
    let insets: EdgeInsets
    let bandHeight: Double
    /// The undo chip is up: the text keeps clear of it at the bottom.
    let reservesChip: Bool
    /// A tap that sends, at the touch point (the preview's own coordinates).
    let onSend: (CGPoint) -> Void
    /// A swipe up: send without cleanup.
    let onSendRaw: () -> Void
    /// A swipe left: clear what is still in the preview.
    let onDiscard: () -> Void

    /// What one drag has done: whether it began at the bottom (a drag that scrolls down to it is not a swipe up) and whether it
    /// already acted. Resets when the drag ends or is cancelled (iOS may cancel a drag that leaves a short view).
    private struct DragMemory { var startedAtBottom: Bool?; var fired = false }
    @GestureState private var drag = DragMemory()
    /// The swoosh: the text lifts and dims a little, then settles back.
    @State private var swoosh = false
    @State private var reveal = PreviewReveal()
    @State private var probe = ExitProbe()
    /// Flips when a reveal finishes, so the timeline pauses again.
    @State private var revealSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When each letter of the leaving unit went into the field (`PreviewRenderer.exits`).
    @State private var exits: [Date] = []
    @State private var settleOffset: CGFloat = 0
    /// The words a clear is taking away, fading out where they were.
    @State private var ghost: String?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var follow = PreviewFollow()
    @State private var metrics = ScrollMetrics()
    @State private var scrollPhase = ScrollPhase.idle
    @State private var resumeTask: Task<Void, Never>?

    private struct ScrollMetrics: Equatable { var offset = 0.0, content = 0.0, container = 0.0 }
    private var distanceFromBottom: Double { metrics.content - metrics.offset - metrics.container }
    private var atBottom: Bool { PreviewFollow.isAtBottom(distance: distanceFromBottom) }
    private var scrollable: Bool { metrics.content > metrics.container + 0.5 }
    private var leaving: Bool { !(layout?.leaving.isEmpty ?? true) }
    private var userScrolling: Bool { scrollPhase == .tracking || scrollPhase == .interacting || scrollPhase == .decelerating }

    private var leavingText: String {
        guard let layout else { return "" }
        return String(Array(layout.text)[layout.leaving.clamped(to: 0..<layout.text.count)])
    }
    private var exited: Int { layout?.exited ?? 0 }

    /// The words a clear would take: the text after the last part the app keeps (the unit being typed, units in cleanup).
    private var clearableText: String {
        guard let layout else { return "" }
        let kept = ([layout.leaving.upperBound] + layout.waiting.map(\.upperBound)).max() ?? 0
        return String(Array(layout.text).dropFirst(min(kept, layout.text.count))).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = WordRowHeight.previewFontSize(rowHeight: bandHeight)
            let _ = revealSettled
            let _ = reveal.update(text: text, placeholders: [KeyboardController.listening, KeyboardController.cleared], enabled: !reduceMotion)
            let animating = exits.contains { Date().timeIntervalSince($0) < PreviewRenderer.fadeSeconds + 0.1 } || reveal.hidden > 0
            let shimmers = !reduceMotion && !(layout?.waiting.isEmpty ?? true)
            let bottomPadding = reservesChip ? PreviewScroll.undoChipHeight + 4 : 2
            ScrollView(.vertical) {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating && !shimmers)) { timeline in
                    let hadHidden = reveal.hidden > 0
                    let settled = reveal.advance(now: timeline.date, total: text.count)
                    let _ = { if hadHidden && settled { Task { @MainActor in revealSettled.toggle() } } }()
                    composed
                        .font(.system(size: CGFloat(size)))
                        .lineSpacing(CGFloat(WordRowHeight.previewLineSpacing(size: size)))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .multilineTextAlignment(.leading)
                        .textRenderer(PreviewRenderer(now: timeline.date, exits: exits, shimmers: shimmers, lifts: !reduceMotion,
                                                      probe: probe, hidden: reveal.hidden))
                }
                .offset(x: settleOffset, y: swoosh ? -Self.swooshLift : 0)
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
            .overlay(alignment: .bottomLeading) { ghostText(size: size, bottomPadding: bottomPadding) }
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
            .onTapGesture(coordinateSpace: .local) { point in
                guard canSend else { return }
                onSend(point)
            }
            // A drag never also taps: the tap fails once the finger has moved. Acts while moving, once per drag: a drag that
            // leaves a short view gets cancelled, so waiting for its end would lose it. Vertical drags still scroll.
            .simultaneousGesture(
                DragGesture(minimumDistance: CGFloat(PreviewScroll.swipeDistance), coordinateSpace: .local)
                    .updating($drag) { value, memory, _ in
                        if memory.startedAtBottom == nil { memory.startedAtBottom = atBottom }
                        guard !memory.fired else { return }
                        switch PreviewScroll.swipe(dx: Double(value.translation.width), dy: Double(value.translation.height),
                                                   startedAtBottom: memory.startedAtBottom ?? false) {
                        case .sendRaw? where canSend:
                            memory.fired = true
                            Task { @MainActor in
                                onSendRaw()
                                playSwoosh()
                            }
                        case .clear? where canDiscard:
                            memory.fired = true
                            Task { @MainActor in
                                clear()
                            }
                        default: break
                        }
                    })
            .onChange(of: exited) { old, new in
                if new > old { exits.append(contentsOf: Array(repeating: Date(), count: new - old)) } else { exits = [] }
                keepExitInView()
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

    /// The words a clear takes fade out where they were (`DictationPreviewView.fadeSeconds`); the preview itself drops them at once.
    /// Reduce Motion: they just go.
    private func clear() {
        let words = clearableText
        if !reduceMotion, !words.isEmpty {
            ghost = words
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.easeOut(duration: DictationPreviewView.fadeSeconds)) { ghost = nil }
            }
        }
        onDiscard()
    }

    @ViewBuilder
    private func ghostText(size: Double, bottomPadding: Double) -> some View {
        if let ghost {
            Text(ghost)
                .font(.system(size: CGFloat(size)))
                .lineSpacing(CGFloat(WordRowHeight.previewLineSpacing(size: size)))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .padding(.bottom, CGFloat(bottomPadding))
                .transition(.opacity)
                .allowsHitTesting(false)
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
