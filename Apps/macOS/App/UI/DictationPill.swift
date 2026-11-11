import AppKit
import Observation
import SwiftUI
import LegatoAppServices
import LegatoComposerUI
import LegatoMac
import LegatoKeyboardCore

/// What the pill shows besides the session itself: a short notice that outlives the run.
@MainActor @Observable
final class DictationPillModel {
    var notice: String?
    var style = NotchIslandStyle.detached
}

/// Never key, never main, never activating: the field underneath keeps focus. Clicks pass through except while a
/// failed cleanup shows its Retry / Insert as-is buttons (`ignoresMouseEvents` is off only then).
private final class DictationPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A click on a button of the (never key) pill acts at once instead of first activating the window.
private final class DictationPillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small island growing out of the notch (a top-centre card without one) while dictation runs: the listening
/// state and the live line, or a readable notice (missing key, no field, microphone). A panel-mode take shows all
/// its words here, growing with them, until they were typed into the app.
@MainActor
final class DictationPillController {
    let model = DictationPillModel()
    private let session: MacDictationSession
    private let takePanel: DictationPanel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var presentGeneration = 0
    private let presentation = IslandPresentation()
    private let occupiedFrame: () -> NSRect?
    private var lastNoticeID = 0
    private static let size = NSSize(width: 460, height: 64)
    private static let failedSize = NSSize(width: 460, height: 92)
    private var size: NSSize {
        let base = session.pipeline.takePhase == .failed || session.instruction.strip.phase != .idle ? Self.failedSize : Self.size
        guard DictationPillView.showsPanel(session: session, panel: takePanel) else { return base }
        return NSSize(width: base.width, height: max(base.height, panelHeight(base: base)))
    }

    /// Room for every word of the panel take at the card's text width, up to half the screen (then the newest words
    /// show and the oldest scroll out at the top).
    private func panelHeight(base: NSSize) -> CGFloat {
        let text = DictationPillView.panelText(session: session, panel: takePanel)
        let width = base.width - 32 - 30 // card padding, then the symbol and its spacing
        let bounds = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let oneLine = ceil(NSFont.systemFont(ofSize: 14).boundingRectForFont.height)
        let limit = ((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800) / 2
        return min(limit, base.height + max(0, ceil(bounds.height) - oneLine))
    }

    /// `occupiedFrame` is the open composer, which a notice must not cover.
    init(session: MacDictationSession, panel: DictationPanel = DictationPanel(), occupiedFrame: @escaping () -> NSRect? = { nil }) {
        self.session = session
        self.takePanel = panel
        self.occupiedFrame = occupiedFrame
        lastNoticeID = session.noticeID
        track()
    }

    /// A notice that does not come from the session (hotkey pressed while the composer is open).
    func show(notice: String) {
        model.notice = notice
        present()
        scheduleHide()
    }

    private func track() {
        withObservationTracking {
            _ = session.phase; _ = session.noticeID; _ = session.pipeline.takePhase; _ = session.instruction.strip.revision
            _ = DictationPillView.panelText(session: session, panel: takePanel); _ = takePanel.inserting; _ = takePanel.active
        } onChange: { [weak self] in
            Task { @MainActor in self?.update(); self?.track() }
        }
    }

    private func update() {
        if session.noticeID != lastNoticeID {
            lastNoticeID = session.noticeID
            model.notice = session.notice
            scheduleHide(seconds: 5)
        }
        let takeShown = session.pipeline.takePhase != .buffering || session.instruction.strip.phase != .idle
            || DictationPillView.showsPanel(session: session, panel: takePanel)
        // Only a failed cleanup takes clicks (Retry, Insert as-is); every other state lets them through.
        panel?.ignoresMouseEvents = session.pipeline.takePhase != .failed && session.instruction.strip.phase == .idle
        if session.phase != .idle || model.notice != nil || takeShown { present() } else { hide() }
    }

    private func scheduleHide(seconds: Double = 4) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            model.notice = nil
            if session.phase == .idle, session.pipeline.takePhase == .buffering, session.instruction.strip.phase == .idle,
               !DictationPillView.showsPanel(session: session, panel: takePanel) { hide() }
        }
    }

    /// Shrinks back into the notch; a `present` meanwhile cancels it.
    private func hide() {
        guard let panel, panel.isVisible, closeTask == nil else { return }
        panel.ignoresMouseEvents = true
        presentation.close()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchIslandTokens.closeDuration + 0.05))
            guard !Task.isCancelled, let self else { return }
            closeTask = nil
            panel.orderOut(nil)
        }
    }

    private func present() {
        presentGeneration += 1
        closeTask?.cancel(); closeTask = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasShown = panel.isVisible
        panel.ignoresMouseEvents = session.pipeline.takePhase != .failed && session.instruction.strip.phase == .idle
        position(panel)
        if !wasShown { presentation.jump(to: false) }
        panel.orderFrontRegardless()
        if wasShown { presentation.open() } else { openSoon() }
    }

    /// One frame at the notch size first, so the grow is drawn instead of skipped.
    private func openSoon() {
        let generation = presentGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, generation == presentGeneration else { return }
            presentation.open()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = DictationPillPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        let hosting = DictationPillHostingView(rootView: DictationPillView(session: session, panel: takePanel, model: model, presentation: presentation))
        // The controller owns the panel frame. SwiftUI's default min/max negotiation feeds
        // the GeometryReader's proposed size back into AppKit when Magic adds its actions.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = self.size
        var style = NotchIslandStyle(screen: screen)
        var frame = NotchGeometry.island(screen: screen.frame, visible: screen.visibleFrame, safeTop: style.safeTop, width: size.width, height: size.height)
        if let occupied = occupiedFrame(), occupied.intersects(frame) {
            style = .detached
            frame = NSRect(x: frame.midX - size.width / 2, y: occupied.minY - 8 - size.height, width: size.width, height: size.height)
        } else if !style.attached {
            frame.origin.y -= 6
        }
        if model.style != style { model.style = style }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

struct DictationPillView: View {
    let session: MacDictationSession
    let panel: DictationPanel
    let model: DictationPillModel
    let presentation: IslandPresentation
    private var pipeline: DictationPipeline { session.pipeline }
    private static let rim = RoundedRectangle(cornerRadius: 18)

    var body: some View {
        NotchIsland(style: model.style, presentation: presentation) { card }
            .accessibilityElement(children: showsFailedActions || session.instruction.strip.phase != .idle ? .contain : .combine)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: session.phase == .listening && model.notice == nil && pipeline.takePhase == .buffering)
                    .frame(width: 20)
                text
            }
            if session.instruction.strip.phase != .idle { magicActions }
            else if showsFailedActions { failedActions }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { CountdownRim(shape: Self.rim, start: pipeline.countdownStart, deadline: pipeline.countdownDeadline, lineWidth: 2).padding(5) }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let caption {
                Text(caption).font(NotchIslandTokens.caption).foregroundStyle(.secondary)
            }
            Text(line)
                .font(NotchIslandTokens.body)
                .foregroundStyle(showsPlaceholder ? .secondary : .primary)
                .lineLimit(inPanel ? nil : caption == nil ? 2 : 1)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: inPanel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var magicActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if session.instruction.strip.phase == .listening {
                Button("Run") { MacAppController.shared.toggleMagic() }.accessibilityIdentifier("magic.run")
            }
            if session.instruction.strip.canUndo {
                Button("Undo") { magic(.undo) }.accessibilityIdentifier("magic.undo")
            }
            if session.instruction.strip.phase == .result || session.instruction.strip.phase == .undone {
                Button("Accept") { magic(.accept) }.accessibilityIdentifier("magic.accept")
            } else if session.instruction.strip.phase == .failed {
                if session.instruction.strip.canRetry != false { Button("Retry") { magic(.run) } }
                Button("Dismiss") { magic(.dismiss) }.accessibilityIdentifier("magic.dismiss")
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }
    private func magic(_ action: InstructionIntent.Action) {
        session.instruction.handle(.init(action: action, instructionID: session.instruction.strip.instructionID))
    }
    private var failedActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Retry") { Task { await pipeline.retry() } }
                .accessibilityIdentifier("dictation.pill.retry")
            Button("Insert as-is") { Task { await pipeline.insertRaw() } }
                .accessibilityIdentifier("dictation.pill.insertRaw")
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var showsFailedActions: Bool { (model.notice == nil || inPanel) && pipeline.takePhase == .failed }
    /// What was said so far: the take's text, then the live words.
    private var spoken: String {
        if inPanel { return Self.panelText(session: session, panel: panel) }
        return [pipeline.takeDisplay, session.tail].filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var showsPlaceholder: Bool { (model.notice == nil || inPanel) && pipeline.takePhase == .buffering && spoken.isEmpty }
    private var inPanel: Bool { Self.showsPanel(session: session, panel: panel) }

    /// A panel-mode take is on show: from the dictation start until its words were typed (or are held after a failed
    /// cleanup). Magic's strip takes precedence while it runs.
    static func showsPanel(session: MacDictationSession, panel: DictationPanel) -> Bool {
        guard panel.active, session.instruction.strip.phase == .idle else { return false }
        return session.phase != .idle || panel.inserting || !panel.take.isEmpty || session.pipeline.takePhase != .buffering
    }

    /// Every word of a panel-mode take: what reached the panel (live runs, cleaned takes, lines), then raw words still
    /// on their way there (a take before its cleaned words stream in, buffered lines, the live line).
    static func panelText(session: MacDictationSession, panel: DictationPanel) -> String {
        let pipeline = session.pipeline
        var parts = [panel.take.text]
        if pipeline.mode != .live {
            if !panel.take.isGrowing { parts.append(pipeline.failedText ?? pipeline.cleaningText ?? "") }
            parts += pipeline.takeLines
            parts.append(session.tail)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var symbol: String {
        if session.instruction.strip.phase != .idle { return session.instruction.strip.phase == .failed ? "exclamationmark.triangle.fill" : "wand.and.stars" }
        if (model.notice != nil && !inPanel) || pipeline.takePhase == .failed { return "exclamationmark.triangle.fill" }
        if inPanel, panel.inserting { return "keyboard" }
        return session.phase == .finishing || pipeline.takePhase == .cleaning ? "ellipsis" : "mic.fill"
    }
    private var tint: Color {
        if (model.notice != nil && !inPanel) || pipeline.takePhase == .failed { return .orange }
        return session.phase == .listening && pipeline.takePhase == .buffering ? .red : .secondary
    }
    /// A state line above the text: the cleanup is running, or failed and the raw text is held.
    private var caption: String? {
        if session.instruction.strip.phase != .idle {
            switch session.instruction.strip.phase {
            case .listening: return "Magic · listening"
            case .reading: return "Magic · reading the field…"
            case .running: return "Magic · editing…"
            case .result, .undone, .failed: return session.instruction.strip.message ?? "Magic"
            case .idle: break
            }
        }
        // In the panel the words stay; a notice takes the caption line instead.
        if inPanel, let notice = model.notice { return notice }
        guard model.notice == nil else { return nil }
        if inPanel, panel.inserting { return "Typing into the app…" }
        switch pipeline.takePhase {
        case .failed: return "Couldn't clean up. Your text is held."
        case .cleaning: return "Cleaning…"
        case .buffering: return nil
        }
    }
    private var line: String {
        if session.instruction.strip.phase != .idle { return session.instruction.strip.transcript.isEmpty ? "Speak an instruction about the text." : session.instruction.strip.transcript }
        if let notice = model.notice, !inPanel { return notice }
        if pipeline.takePhase != .buffering { return spoken }
        if !spoken.isEmpty { return spoken }
        switch session.phase {
        case .starting: return "Starting…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .idle: return ""
        }
    }
}
