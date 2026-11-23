import AppKit
import Observation
import SwiftUI
import LegatoAppServices
import LegatoComposerUI
import LegatoKeyboardCore

struct DictationPillActions {
    var magic: @MainActor () -> Void
    var instruction: @MainActor () -> Void
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
    let diff: PreviewRewriteDiff
    let start = Date()

    init(source: String, result: String) {
        self.source = source
        diff = PreviewRewriteDiff(original: source, target: result)
    }
}

@MainActor @Observable private final class ComposerPresentation {
    var notice: String?
    var text = ""
    var instruction = ""
    var message: String?
    var status = ""
    var instructing = false
    var correcting = false
    var interactive = false
    var rewrite: ComposerMagicRewrite?
    var departure: MacComposerDraft.Dismissal?
}

@MainActor final class DictationPillController {
    private let session: MacDictationSession
    private let settings: MacSettings
    private let actions: DictationPillActions
    private let model = ComposerPresentation()
    private let presentation = IslandPresentation()
    private var panel: NSPanel?
    private var noticeTask: Task<Void, Never>?
    private var departureTask: Task<Void, Never>?
    private var lastNoticeID: Int
    private var lastRewriteID: Int?
    private var caret: NSRect?
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
        let anchor = witness.composerAnchor()
        caret = anchor.caret.map(Self.flipCoordinates)
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
        departureTask?.cancel()
        departureTask = nil
        model.departure = nil
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
            model.rewrite = revision.source != text && revision.result == text
                ? ComposerMagicRewrite(source: revision.source, result: text) : nil
        } else if text != model.text {
            model.rewrite = nil
        }
        model.text = text
        model.instructing = session.speechMode == .instruction
        model.instruction = model.instructing ? session.instruction.strip.transcript : ""
        model.correcting = draft.isCorrecting
        model.message = model.notice ?? draft.message
        model.interactive = interactive
        if draft.isCorrecting { model.status = "Magic is revising…" }
        else if model.instructing { model.status = "Listening for an instruction…" }
        else {
            switch session.phase {
            case .starting: model.status = "Starting…"
            case .finishing: model.status = "Finishing…"
            case .listening: model.status = "Listening…"
            case .idle: model.status = "Draft"
            }
        }
    }

    private func depart(_ dismissal: MacComposerDraft.Dismissal) {
        // The window's last rendered content stays still while delivery or cancellation finishes.
        // It has already handed input back to the editor.
        panel?.ignoresMouseEvents = true
        RealInput.shared.setOwnArea(.null)
        noticeTask?.cancel()
        model.notice = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hidePanel()
            return
        }
        model.departure = dismissal
        departureTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(NotchIslandTokens.departureDuration)) }
            catch { return }
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        departureTask?.cancel()
        departureTask = nil
        panel?.orderOut(nil)
        RealInput.shared.setOwnArea(.null)
        presentation.jump(to: false)
        model.departure = nil
        model.rewrite = nil
        model.text = ""
        model.instruction = ""
        model.message = nil
        model.interactive = false
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
        let anchor = caret ?? hostWindow
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let inset = NotchIslandTokens.panelOuterInset
        let visible = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        guard visible.width > 0, visible.height > 0 else { return }
        let width = min(NotchIslandTokens.panelWidth, visible.width)
        let font = NSFont.systemFont(ofSize: NotchIslandTokens.bodyPointSize)
        let available = NSSize(width: max(1, width - 2 * NotchIslandTokens.panelHorizontalInset),
                               height: .greatestFiniteMagnitude)
        let lines = [model.text, model.instruction, model.message ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        let textHeight = (lines as NSString).boundingRect(with: available, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                          attributes: [.font: font]).height
        let maxHeight = min(NotchIslandTokens.panelMaxHeight, visible.height)
        let height = min(max(NotchIslandTokens.panelMinHeight, NotchIslandTokens.panelChromeHeight + ceil(textHeight)), maxHeight)
        let gap = NotchIslandTokens.caretGap
        let frame: NSRect
        if let caret, screen.frame.contains(CGPoint(x: caret.midX, y: caret.midY)),
           caret.minY - gap > visible.minY || caret.maxY + gap < visible.maxY {
            let below = caret.minY - visible.minY - gap
            let above = visible.maxY - caret.maxY - gap
            // Pick a side using the full height so the panel sticks to its edge as the draft grows.
            let placeBelow = below >= maxHeight || below >= above
            let room = max(1, placeBelow ? below : above)
            let fitted = min(height, room)
            frame = NSRect(x: min(max(caret.minX, visible.minX), visible.maxX - width),
                           y: placeBelow ? caret.minY - gap - fitted : caret.maxY + gap,
                           width: width, height: fitted)
        } else {
            let window = hostWindow?.intersection(visible)
            let area = window.flatMap { $0.isEmpty ? nil : $0 } ?? visible
            frame = NSRect(x: min(max(area.midX - width / 2, visible.minX), visible.maxX - width),
                           y: max(visible.minY, area.maxY - height - inset), width: width, height: height)
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
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
    private var departureOffset: CGFloat {
        switch model.departure {
        case .insert?: NotchIslandTokens.departureTravel
        case .discard?: -NotchIslandTokens.departureTravel
        case nil: 0
        }
    }

    var body: some View {
        NotchIsland(style: .detached, presentation: presentation) {
            VStack(alignment: .leading, spacing: 7) {
                if model.interactive {
                    Label(model.status, systemImage: magic ? "wand.and.stars" : "waveform")
                        .font(NotchIslandTokens.caption)
                        .foregroundStyle(magic ? Color.purple : .secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.text.isEmpty {
                            ComposerDraftText(text: model.text, correcting: model.correcting, rewrite: model.rewrite)
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
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                if model.interactive { toolbar }
            }
            .padding(.horizontal, NotchIslandTokens.panelHorizontalInset)
            .padding(.vertical, 8)
            .background {
                if magic {
                    MagicPreviewGlow().transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .smooth, value: magic)
            .accessibilityElement(children: .contain)
        }
        .offset(x: reduceMotion ? 0 : departureOffset)
        .scaleEffect(model.departure == nil || reduceMotion ? 1 : 0.97)
        .opacity(model.departure == nil ? 1 : 0)
        .animation(reduceMotion ? nil : NotchIslandTokens.departureSpring, value: model.departure)
        .accessibilityHidden(model.departure != nil)
        .task(id: model.rewrite?.start) {
            guard let start = model.rewrite?.start else { return }
            do { try await Task.sleep(for: .seconds(MagicPreviewEffects.poofSeconds + 0.10)) }
            catch { return }
            if model.rewrite?.start == start { model.rewrite = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            action(.discard, actions.discard)
            Spacer(minLength: 0)
            Button(action: actions.instruction) {
                Image(systemName: model.instructing ? "stop.circle" : "mic")
            }
            .accessibilityLabel(model.instructing ? "Run spoken instruction" : "Speak an instruction")
            .help(model.instructing ? "Run spoken instruction" : "Speak an instruction")
            .accessibilityIdentifier("composer.instruction")
            .disabled(model.correcting || (model.text.isEmpty && !model.instructing))
            action(.magic, actions.magic)
            action(.insert, actions.insert)
        }.buttonStyle(.bordered).controlSize(.small)
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

private enum ComposerGlyph: TextAttribute, Equatable { case poof, incoming, hidden }

private struct ComposerDraftText: View {
    let text: String
    let correcting: Bool
    let rewrite: ComposerMagicRewrite?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || (!correcting && rewrite == nil) {
            Text(verbatim: text)
        } else {
            animatedText.accessibilityLabel(Text(verbatim: text))
        }
    }

    private var animatedText: some View {
        let previous = rewrite.flatMap { rewrite in
            rewrite.diff.removed.isEmpty ? nil : MagicPreviewEffects.marked(rewrite.source) {
                rewrite.diff.removed.contains($0) ? ComposerGlyph.poof : .hidden
            }
        }
        let current = rewrite.map { rewrite in
            MagicPreviewEffects.marked(text) { rewrite.diff.inserted.contains($0) ? ComposerGlyph.incoming : nil }
        } ?? Text(verbatim: text)
        return TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let elapsed = rewrite.map { timeline.date.timeIntervalSince($0.start) } ?? 0
            ZStack(alignment: .bottomLeading) {
                if let previous {
                    previous.textRenderer(ComposerGlyphRenderer(date: timeline.date, elapsed: elapsed, correcting: false))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                current.textRenderer(ComposerGlyphRenderer(date: timeline.date, elapsed: elapsed, correcting: correcting))
            }
        }
    }
}

private struct ComposerGlyphRenderer: TextRenderer {
    let date: Date
    let elapsed: Double
    let correcting: Bool

    var displayPadding: EdgeInsets { EdgeInsets(top: MagicPreviewEffects.lift, leading: 0, bottom: 0, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let progress = min(1, max(0, elapsed / MagicPreviewEffects.poofSeconds))
        let entrance = min(1, max(0, (elapsed - 0.10) / MagicPreviewEffects.poofSeconds))
        var shimmers: [Text.Layout.RunSlice] = []
        for line in layout {
            for run in line {
                switch run[ComposerGlyph.self] {
                case .hidden?: break
                case .poof?: MagicPreviewEffects.drawPoof(run, progress: progress, in: context)
                case .incoming?:
                    var entranceContext = context
                    entranceContext.opacity = entrance
                    entranceContext.translateBy(x: 0, y: MagicPreviewEffects.lift * (1 - entrance))
                    entranceContext.draw(run)
                case nil:
                    context.draw(run)
                    if correcting { shimmers.append(contentsOf: run) }
                }
            }
        }
        MagicPreviewEffects.drawShimmer(shimmers, in: layout, now: date, context: context)
    }
}
