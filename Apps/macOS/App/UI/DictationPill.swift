import AppKit
import Observation
import SwiftUI
import LegatoAppServices
import LegatoKeyboardCore

struct DictationPillActions {
    var magic: @MainActor () -> Void
    var instruction: @MainActor () -> Void
    var insert: @MainActor () -> Void
    var discard: @MainActor () -> Void
    var undoDiscard: @MainActor () -> Void
    var copy: @MainActor () -> Void
}

extension MacComposerShortcut {
    var actionTitle: String {
        switch self {
        case .magic: "Magic"
        case .insert: "Insert"
        case .discard: "Discard"
        case .undoDiscard: "Undo Discard"
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

@MainActor @Observable private final class ComposerPresentation {
    var notice: String?
}

@MainActor final class DictationPillController {
    private let session: MacDictationSession
    private let actions: DictationPillActions
    private let model = ComposerPresentation()
    private let presentation = IslandPresentation()
    private var panel: NSPanel?
    private var noticeTask: Task<Void, Never>?
    private var lastNoticeID: Int
    private var caret: NSRect?
    private var hostWindow: NSRect?

    init(session: MacDictationSession, actions: DictationPillActions) {
        self.session = session
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
            _ = session.composer?.canUndoDiscard
            _ = session.composer?.isCorrecting
            _ = session.composer?.isInserting
            _ = session.composer?.needsCopy
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
        guard session.isActive || !draft.isEmpty || draft.isCorrecting || draft.isInserting
                || draft.canUndoDiscard || draft.message != nil || model.notice != nil else {
            panel?.orderOut(nil)
            RealInput.shared.setOwnArea(.null)
            presentation.jump(to: false)
            return
        }
        let panel = self.panel ?? makePanel(draft: draft)
        self.panel = panel
        position(panel, draft: draft)
        RealInput.shared.setOwnArea(Self.flipCoordinates(panel.frame))
        panel.orderFrontRegardless()
        presentation.open()
    }

    private func makePanel(draft: MacComposerDraft) -> NSPanel {
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
        let content = DictationPillView(session: session, draft: draft, actions: actions, model: model, presentation: presentation)
        let hosting = DictationPillHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel, draft: MacComposerDraft) {
        let anchor = caret ?? hostWindow
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(460, visible.width)
        let font = NSFont.systemFont(ofSize: 14)
        let available = NSSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)
        let lines = [draft.text, session.speechMode == .instruction ? session.instruction.strip.transcript : "",
                     model.notice ?? draft.message ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        let textHeight = (lines as NSString).boundingRect(with: available, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                          attributes: [.font: font]).height
        let height = min(max(104, 90 + ceil(textHeight)), visible.height / 2)
        let origin: CGPoint
        if let caret {
            let below = caret.minY - height - 6
            origin = CGPoint(x: caret.minX, y: below >= visible.minY ? below : caret.maxY + 6)
        } else {
            let window = hostWindow?.intersection(visible)
            let area = window.flatMap { $0.isEmpty ? nil : $0 } ?? visible
            origin = CGPoint(x: area.midX - width / 2, y: area.maxY - height - 12)
        }
        let frame = NSRect(x: min(max(origin.x, visible.minX), visible.maxX - width),
                           y: min(max(origin.y, visible.minY), visible.maxY - height), width: width, height: height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}

private struct DictationPillView: View {
    let session: MacDictationSession
    let draft: MacComposerDraft
    let actions: DictationPillActions
    let model: ComposerPresentation
    let presentation: IslandPresentation
    private var instructing: Bool { session.speechMode == .instruction }
    private var busy: Bool { draft.isCorrecting || draft.isInserting }
    private var status: String {
        if draft.isInserting { return "Inserting…" }
        if draft.isCorrecting { return "Magic is revising…" }
        if instructing { return "Listening for an instruction…" }
        switch session.phase {
        case .starting: return "Starting…"
        case .finishing: return "Finishing…"
        case .listening: return "Listening…"
        case .idle: return draft.isEmpty && draft.canUndoDiscard ? "Draft discarded" : "Draft"
        }
    }

    var body: some View {
        NotchIsland(style: .detached, presentation: presentation) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: busy || instructing ? "wand.and.stars" : "waveform")
                        .foregroundStyle(instructing || draft.isCorrecting ? Color.purple : .secondary)
                    Text(status)
                }.font(NotchIslandTokens.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !draft.text.isEmpty {
                            Text(draft.text).font(NotchIslandTokens.body)
                                .accessibilityIdentifier("dictation.pill.panelText")
                        }
                        if instructing, !session.instruction.strip.transcript.isEmpty {
                            Text(session.instruction.strip.transcript).font(NotchIslandTokens.body).foregroundStyle(.purple)
                                .accessibilityLabel("Instruction: \(session.instruction.strip.transcript)")
                        }
                        if let notice = model.notice ?? draft.message {
                            Text(notice).font(NotchIslandTokens.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                HStack(spacing: 6) {
                    if draft.canUndoDiscard {
                        action(.undoDiscard, "arrow.uturn.backward", actions.undoDiscard)
                    } else {
                        action(.discard, "trash", actions.discard)
                            .disabled(draft.isInserting || (draft.isEmpty && !session.isActive))
                    }
                    Spacer(minLength: 0)
                    if draft.needsCopy {
                        Button("Copy", action: actions.copy).accessibilityIdentifier("composer.copy")
                    } else {
                        Button(action: actions.instruction) {
                            Image(systemName: instructing ? "stop.circle" : "mic")
                        }
                        .accessibilityLabel(instructing ? "Run spoken instruction" : "Speak an instruction")
                        .help(instructing ? "Run spoken instruction" : "Speak an instruction")
                        .accessibilityIdentifier("composer.instruction")
                        .disabled(busy || (draft.isEmpty && !instructing))
                        action(.magic, "wand.and.stars", actions.magic)
                            .disabled(draft.isEmpty || busy || instructing)
                        action(.insert, "return", actions.insert)
                            .disabled(draft.isEmpty || busy || instructing)
                    }
                }.buttonStyle(.bordered).controlSize(.small)
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .accessibilityElement(children: .contain)
        }
    }

    private func action(_ shortcut: MacComposerShortcut, _ symbol: String, _ perform: @escaping @MainActor () -> Void) -> some View {
        Button(action: perform) { Label(shortcut.actionTitle, systemImage: symbol) }
            .help("\(shortcut.actionTitle) (\(shortcut.keysLabel))")
            .accessibilityIdentifier("composer.\(shortcut)")
    }
}
