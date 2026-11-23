import AppKit
import Observation
import SwiftUI
import LegatoAppServices
import LegatoComposerUI
import LegatoKeyboardCore

struct DictationPillActions {
    var magic: @MainActor () -> Void
    var instruction: @MainActor () -> Void
    var dictation: @MainActor () -> Void
    var insert: @MainActor () -> Void
    var discard: @MainActor () -> Void
}

extension MacComposerShortcut {
    var actionTitle: String {
        switch self {
        case .magic: "Magic"
        case .insert: "Insert"
        case .discard: "Discard"
        }
    }
}

/// The destination keeps focus while its composer receives first-click button actions.
private final class DictationPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class DictationPillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ComposerMagicRewrite {
    let source: String
    let result: String
    let diff: PreviewRewriteDiff
    let start = Date()
    let glyphsPerPiece: Int

    static let duration = MagicPreviewEffects.poofSeconds / 2 + ChunkEntrance.capMs / 1000 + MagicPreviewEffects.entranceSeconds

    init(source: String, result: String) {
        self.source = source
        self.result = result
        diff = PreviewRewriteDiff(original: source, target: result)
        let pieces = Int(ChunkEntrance.capMs / ChunkEntrance.gapMs) + 1
        glyphsPerPiece = max(1, (diff.inserted.count + pieces - 1) / pieces)
    }
}

private struct ComposerDeparture {
    let action: MacComposerDraft.Dismissal
    let id = UUID()
    let start = Date()
}

@MainActor @Observable private final class ComposerPresentation {
    var notice: String?
    var text = ""
    var instruction = ""
    var message: String?
    var phase = MacDictationSession.Phase.idle
    var instructing = false
    var correcting = false
    var interactive = false
    var rewrite: ComposerMagicRewrite?
    var departure: ComposerDeparture?
    var attachment = IslandAttachment.top
    var rippleStart: Date?
}

@MainActor final class DictationPillController {
    private let session: MacDictationSession
    private let settings: MacSettings
    private let actions: DictationPillActions
    private let model = ComposerPresentation()
    private let presentation = IslandPresentation()
    private var panel: NSPanel?
    private var noticeTask: Task<Void, Never>?
    private var lastNoticeID: Int
    private var lastRewriteID: Int?
    private var caret: NSRect?
    private var focusedField: NSRect?
    private var hostWindow: NSRect?

    init(session: MacDictationSession, settings: MacSettings, actions: DictationPillActions) {
        self.session = session
        self.settings = settings
        self.actions = actions
        lastNoticeID = session.noticeID
        track()
    }

    /// Held for the life of a draft, including stops, resumed dictation and Magic revisions.
    func captureAnchor(_ witness: AXTextTarget.PasteWitness) {
        let anchor = witness.composerAnchor { rect in
            let frame = Self.flipCoordinates(rect)
            return NSScreen.screens.contains { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        }
        caret = anchor.caret.map(Self.flipCoordinates)
        focusedField = anchor.field.map(Self.flipCoordinates)
        hostWindow = anchor.window.map(Self.flipCoordinates)
        if panel?.isVisible == true { update() }
    }

    /// Quartz uses the primary screen's top edge, AppKit its bottom edge. Flipping works in
    /// either direction, including on monitors left of or above the primary screen.
    private static func flipCoordinates(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    func show(notice: String) {
        model.notice = notice
        update()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            model.notice = nil
            update()
        }
    }

    private func track() {
        withObservationTracking {
            _ = session.phase
            _ = session.noticeID
            _ = session.speechMode
            _ = session.instruction.strip.revision
            _ = session.composer?.text
            _ = session.isActivityInteractive
            _ = session.composer?.dismissal
            _ = session.composer?.visualRevision
            _ = session.composer?.isCorrecting
            _ = session.composer?.isInserting
            _ = session.composer?.message
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if lastNoticeID != session.noticeID {
                    lastNoticeID = session.noticeID
                    if let notice = session.notice { show(notice: notice) }
                }
                update()
                track()
            }
        }
    }

    private func update() {
        guard let draft = session.composer else { return }
        let interactive = session.isActivityInteractive
        if let dismissal = draft.dismissal, !interactive {
            if panel?.isVisible == true, model.departure == nil { depart(dismissal) }
            return
        }
        guard interactive || draft.message != nil || model.notice != nil else {
            hidePanel()
            return
        }
        if model.departure != nil {
            model.departure = nil
            model.rewrite = nil
        }
        updateContent(draft, interactive: interactive)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.ignoresMouseEvents = !interactive
        RealInput.shared.setOwnArea(interactive ? Self.flipCoordinates(panel.frame) : .null)
        panel.orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            presentation.jump(to: true)
        } else {
            presentation.open()
        }
    }

    private func updateContent(_ draft: MacComposerDraft, interactive: Bool) {
        let text = draft.text
        if let revision = draft.visualRevision, revision.id != lastRewriteID {
            lastRewriteID = revision.id
            model.rewrite = revision.source != revision.result && text.hasPrefix(revision.result)
                ? ComposerMagicRewrite(source: revision.source, result: revision.result) : nil
        } else if let rewrite = model.rewrite, !text.hasPrefix(rewrite.result) {
            model.rewrite = nil
        }
        let instructing = session.speechMode == .instruction
        if (instructing && !model.instructing) || (draft.isCorrecting && !model.correcting) {
            model.rippleStart = Date()
        }
        model.text = text
        model.instructing = instructing
        model.instruction = instructing ? session.instruction.strip.transcript : ""
        model.correcting = draft.isCorrecting
        model.message = model.notice ?? draft.message
        model.interactive = interactive
        model.phase = session.phase
    }

    private func depart(_ dismissal: MacComposerDraft.Dismissal) {
        // Keeping the frame and snapshot unchanged makes the text a single departing block.
        panel?.ignoresMouseEvents = true
        RealInput.shared.setOwnArea(.null)
        noticeTask?.cancel()
        model.notice = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hidePanel()
            return
        }
        let departure = ComposerDeparture(action: dismissal)
        withAnimation(NotchIslandTokens.departureSpring, completionCriteria: .logicallyComplete) {
            model.departure = departure
        } completion: { [weak self] in
            guard let self, model.departure?.id == departure.id else { return }
            hidePanel()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        RealInput.shared.setOwnArea(.null)
        presentation.jump(to: false)
        model.departure = nil
        model.rewrite = nil
        model.rippleStart = nil
        model.text = ""
        model.instruction = ""
        model.message = nil
        model.interactive = false
        model.instructing = false
        model.correcting = false
    }

    private func makePanel() -> NSPanel {
        let panel = DictationPillPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let content = DictationPillView(session: session, settings: settings, actions: actions, model: model, presentation: presentation)
        let hosting = DictationPillHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        let anchor = caret ?? focusedField ?? hostWindow
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let inset = NotchIslandTokens.panelOuterInset
        let visible = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        guard visible.width > 0, visible.height > 0 else { return }
        let width = min(NotchIslandTokens.panelWidth, visible.width)
        let height = naturalHeight(width: width)
        let gap = NotchIslandTokens.caretGap
        let nearby = caret ?? focusedField
        let toolbar = NotchIslandTokens.toolbarHeight + 2 * NotchIslandTokens.panelVerticalInset
        let frame: NSRect
        if let nearby, screen.frame.contains(CGPoint(x: nearby.midX, y: nearby.midY)),
           nearby.minY - gap - visible.minY >= toolbar || visible.maxY - nearby.maxY - gap >= toolbar {
            let below = nearby.minY - visible.minY - gap
            let above = visible.maxY - nearby.maxY - gap
            // Prefer below when it has enough room for the controls and a few lines.
            // The chosen edge is independent of the current text length.
            let openingRoom = toolbar + 4 * NSFont.systemFont(ofSize: NotchIslandTokens.bodyPointSize).boundingRectForFont.height
            let placeBelow = below >= openingRoom || below >= above
            let fitted = min(height, placeBelow ? below : above)
            model.attachment = placeBelow ? .top : .bottom
            frame = NSRect(x: min(max(nearby.minX, visible.minX), visible.maxX - width),
                           y: placeBelow ? nearby.minY - gap - fitted : nearby.maxY + gap,
                           width: width, height: fitted)
        } else {
            let window = hostWindow?.intersection(visible)
            let area = window.flatMap { $0.isEmpty ? nil : $0 } ?? visible
            let top = min(max(area.maxY - inset, visible.minY + 1), visible.maxY)
            let fitted = min(height, max(1, top - visible.minY))
            model.attachment = .top
            frame = NSRect(x: min(max(area.midX - width / 2, visible.minX), visible.maxX - width),
                           y: top - fitted, width: width, height: fitted)
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func naturalHeight(width: CGFloat) -> CGFloat {
        let available = NSSize(width: max(1, width - 2 * NotchIslandTokens.panelHorizontalInset),
                               height: .greatestFiniteMagnitude)
        let body = NSFont.systemFont(ofSize: NotchIslandTokens.bodyPointSize)
        let caption = NSFont.systemFont(ofSize: NotchIslandTokens.captionPointSize, weight: .medium)
        let lines = [(model.text, body), (model.instruction, body), (model.message ?? "", caption)].filter { !$0.0.isEmpty }
        let textHeight = lines.reduce(CGFloat.zero) { height, line in
            let bounds = (line.0 as NSString).boundingRect(with: available,
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: line.1])
            return height + ceil(bounds.height)
        }
        let textSpacing = CGFloat(max(0, lines.count - 1)) * NotchIslandTokens.draftLineSpacing
        let toolbar = NotchIslandTokens.toolbarHeight + (lines.isEmpty ? 0 : NotchIslandTokens.panelSectionSpacing)
        return 2 * NotchIslandTokens.panelVerticalInset + textHeight + textSpacing + (model.interactive ? toolbar : 0)
    }
}

private struct DictationPillView: View {
    let session: MacDictationSession
    let settings: MacSettings
    let actions: DictationPillActions
    let model: ComposerPresentation
    let presentation: IslandPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var magic: Bool { model.instructing || model.correcting }
    private var departing: Bool { model.departure != nil }
    private var discarding: Bool { model.departure?.action == .discard }
    private var draftLift: CGFloat { model.departure?.action == .insert ? NotchIslandTokens.departureTextLift : 0 }

    var body: some View {
        NotchIsland(style: .detached, presentation: presentation, attachment: model.attachment, departing: departing) {
            VStack(alignment: .leading, spacing: NotchIslandTokens.panelSectionSpacing) {
                if hasDraftContent {
                    draftViewport
                        .offset(y: -draftLift)
                        .opacity(departing ? 0 : 1)
                }
                if model.interactive {
                    toolbar.opacity(departing ? 0 : 1)
                }
            }
            .scaleEffect(discarding ? 0.96 : 1, anchor: model.attachment.anchor)
            .padding(.horizontal, NotchIslandTokens.panelHorizontalInset)
            .padding(.vertical, NotchIslandTokens.panelVerticalInset)
            .accessibilityElement(children: .contain)
        }
        .accessibilityHidden(departing)
        .task(id: model.rewrite?.start) {
            guard let start = model.rewrite?.start else { return }
            do { try await Task.sleep(for: .seconds(ComposerMagicRewrite.duration)) }
            catch { return }
            if model.rewrite?.start == start, !departing { model.rewrite = nil }
        }
        .task(id: model.rippleStart) {
            guard let start = model.rippleStart else { return }
            do { try await Task.sleep(for: .seconds(MagicPreviewRipple.seconds)) }
            catch { return }
            if model.rippleStart == start { model.rippleStart = nil }
        }
    }

    private var hasDraftContent: Bool { !model.text.isEmpty || !model.instruction.isEmpty || model.message != nil }

    private var draftViewport: some View {
        ViewThatFits(in: .vertical) {
            draftContent.fixedSize(horizontal: false, vertical: true)
            ComposerOverflow(frozen: departing) { draftContent }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                if magic {
                    MagicPreviewGlow().transition(.opacity)
                }
                if let start = model.rippleStart, !departing {
                    MagicPreviewRipple(start: start)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion || departing ? nil : .smooth, value: magic)
    }

    private var draftContent: some View {
        VStack(alignment: .leading, spacing: NotchIslandTokens.draftLineSpacing) {
            if !model.text.isEmpty {
                ComposerDraftText(text: model.text, correcting: model.correcting, rewrite: model.rewrite,
                                  frozenAt: model.departure?.start)
                    .font(NotchIslandTokens.body)
                    .accessibilityIdentifier("dictation.pill.panelText")
            }
            if !model.instruction.isEmpty {
                Text(verbatim: model.instruction).font(NotchIslandTokens.body).foregroundStyle(.purple)
                    .accessibilityLabel("Instruction: \(model.instruction)")
            }
            if let message = model.message {
                Text(message).font(NotchIslandTokens.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            action(.discard, actions.discard)
            Spacer(minLength: 0)
            microphone
            magicControl
            action(.insert, actions.insert)
        }
        .frame(height: NotchIslandTokens.toolbarHeight)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var microphone: some View {
        let listens = model.phase == .listening || model.phase == .starting
        let finishing = model.phase == .finishing
        let label = listens ? "Pause dictation" : finishing ? "Pausing dictation" : "Resume dictation"
        let keys = settings.dictationHotkey?.displayName
        return Button(action: actions.dictation) {
            Image(systemName: listens || finishing ? "mic.fill" : "mic.slash")
                .foregroundStyle(model.phase == .listening ? Color.red : Color.secondary)
        }
        .help(keys.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
        .accessibilityValue(model.phase == .listening ? "Listening" : model.phase == .starting ? "Starting" : finishing ? "Finishing" : "Paused")
        .accessibilityIdentifier("composer.dictation")
        .disabled(finishing)
    }

    private var magicControl: some View {
        HStack(spacing: 1) {
            action(.magic, actions.magic)
            Button(action: actions.instruction) {
                Image(systemName: model.instructing ? "stop.fill" : "waveform")
                    .foregroundStyle(Color.purple)
            }
            .accessibilityLabel(model.instructing ? "Run spoken Magic instruction" : "Speak a Magic instruction")
            .help(model.instructing ? "Run spoken Magic instruction" : "Speak a Magic instruction")
            .accessibilityIdentifier("composer.instruction")
            .disabled(model.correcting || (!model.instructing && !MacComposerShortcut.magic.isAvailable(in: session)))
        }
        .padding(2)
        .background(.purple.opacity(magic ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }

    private func action(_ shortcut: MacComposerShortcut, _ perform: @escaping @MainActor () -> Void) -> some View {
        let keys = settings.binding(for: shortcut)?.displayName
        return Button(action: perform) {
            HStack(spacing: 4) {
                if shortcut == .discard, let keys { shortcutHint(keys) }
                if shortcut == .magic { Image(systemName: "sparkle").foregroundStyle(.purple) }
                Text(shortcut.actionTitle)
                if shortcut != .discard, let keys { shortcutHint(keys) }
            }.lineLimit(1)
        }
        .help(keys.map { "\(shortcut.actionTitle) (\($0))" } ?? shortcut.actionTitle)
        .accessibilityIdentifier("composer.\(shortcut)")
        .disabled(!shortcut.isAvailable(in: session))
    }

    private func shortcutHint(_ keys: String) -> some View {
        Text(keys).font(.caption).foregroundStyle(.secondary)
    }
}

/// Only the overflowing draft owns a ScrollView, with a visible position indicator independent of scrollbar settings.
private struct ComposerOverflow<Content: View>: View {
    let frozen: Bool
    @ViewBuilder var content: Content
    @State private var position = Position()

    private struct Position: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0

        var thumbHeight: CGFloat { min(viewport, max(16, viewport * viewport / max(1, content))) }
        var thumbOffset: CGFloat {
            let progress = min(1, max(0, offset / max(1, content - viewport)))
            return (viewport - thumbHeight) * progress
        }
    }

    var body: some View {
        ScrollView {
            content.fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 2 * NotchIslandTokens.scrollIndicatorWidth)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollIndicators(.never)
        .scrollDisabled(frozen)
        .onScrollGeometryChange(for: Position.self) { geometry in
            Position(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                     viewport: geometry.containerSize.height)
        } action: { _, new in
            if !frozen { position = new }
        }
        .overlay(alignment: .topTrailing) {
            if position.content > position.viewport {
                Capsule()
                    .fill(.white.opacity(0.48))
                    .frame(width: NotchIslandTokens.scrollIndicatorWidth, height: position.thumbHeight)
                    .offset(y: position.thumbOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum ComposerGlyph: TextAttribute, Equatable {
    case poof
    case survivor(Int)
    case incoming(Int)
}

/// Both layers use source grapheme identities, even when a line wraps differently or a glyph spans scalars.
private final class ComposerRewriteReference {
    var glyphs: [Int: CGRect] = [:]
}

private struct ComposerDraftText: View {
    let text: String
    let correcting: Bool
    let rewrite: ComposerMagicRewrite?
    var frozenAt: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reference = ComposerRewriteReference()

    var body: some View {
        if reduceMotion || (!correcting && rewrite == nil) {
            Text(verbatim: text)
        } else {
            animatedText.accessibilityLabel(Text(verbatim: text))
        }
    }

    private var animatedText: some View {
        let trailing = rewrite.map { String(text.dropFirst($0.result.count)) } ?? ""
        let previous = rewrite.map { rewrite in
            MagicPreviewEffects.marked(rewrite.source + trailing) { index in
                if rewrite.diff.removed.contains(index) { return ComposerGlyph.poof }
                return .survivor(index)
            }
        }
        let current = rewrite.map { rewrite in
            let targetCount = rewrite.result.count
            let sourceCount = rewrite.source.count
            var entrance = 0
            return MagicPreviewEffects.marked(text) { index -> ComposerGlyph? in
                if let oldIndex = rewrite.diff.survivors[index] { return .survivor(oldIndex) }
                if index >= targetCount { return .survivor(sourceCount + index - targetCount) }
                defer { entrance += 1 }
                return .incoming(entrance)
            }
        } ?? Text(verbatim: text)

        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: frozenAt != nil)) { timeline in
            let date = frozenAt ?? timeline.date
            let elapsed = rewrite.map { date.timeIntervalSince($0.start) } ?? 0
            current
                .textRenderer(ComposerGlyphRenderer(date: date, elapsed: elapsed, correcting: correcting,
                                                     reference: reference, glyphsPerPiece: rewrite?.glyphsPerPiece ?? 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    if let previous {
                        previous
                            .textRenderer(ComposerGlyphRenderer(date: date, elapsed: elapsed, correcting: false,
                                                                 reference: reference, capturesReference: true))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct ComposerGlyphRenderer: TextRenderer {
    let date: Date
    let elapsed: Double
    let correcting: Bool
    let reference: ComposerRewriteReference
    var glyphsPerPiece = 1
    var capturesReference = false

    var displayPadding: EdgeInsets { EdgeInsets(top: MagicPreviewEffects.lift, leading: 0, bottom: 0, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let poof = min(1, max(0, elapsed / MagicPreviewEffects.poofSeconds))
        if capturesReference { reference.glyphs.removeAll(keepingCapacity: true) }
        var shimmers: [Text.Layout.RunSlice] = []
        for line in layout {
            for run in line {
                switch run[ComposerGlyph.self] {
                case .poof?: MagicPreviewEffects.drawPoof(run, progress: poof, in: context)
                case .incoming(let ordinal)?:
                    let delay = Double(ordinal / glyphsPerPiece) * ChunkEntrance.gapMs / 1000
                    let progress = min(1, max(0, (elapsed - MagicPreviewEffects.poofSeconds / 2 - delay) /
                                                 MagicPreviewEffects.entranceSeconds))
                    for glyph in run { MagicPreviewEffects.drawEntrance(glyph, progress: progress, in: context) }
                case .survivor(let index)?:
                    if capturesReference {
                        let bounds = run.typographicBounds.rect
                        reference.glyphs[index] = reference.glyphs[index].map { $0.union(bounds) } ?? bounds
                    } else if let old = reference.glyphs[index], poof < 1 {
                        let anchor = run.typographicBounds.rect
                        for glyph in run {
                            let rect = glyph.typographicBounds.rect
                            MagicPreviewEffects.drawSurvivor(glyph, from: old.offsetBy(dx: rect.minX - anchor.minX,
                                                                                      dy: rect.minY - anchor.minY),
                                                             progress: poof, in: context)
                        }
                    } else {
                        context.draw(run)
                    }
                case nil:
                    context.draw(run)
                    if correcting { shimmers.append(contentsOf: run) }
                }
            }
        }
        MagicPreviewEffects.drawShimmer(shimmers, in: layout, now: date, context: context)
    }
}
