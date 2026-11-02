import AppKit
import Observation
import SwiftUI
import LegatoAppServices
import LegatoComposerUI
import LegatoMac

/// What the pill shows besides the session itself: a short notice that outlives the run.
@MainActor @Observable
final class DictationPillModel {
    var notice: String?
}

/// Never key, never main, never activating: the field underneath keeps focus. Clicks pass through except while a
/// failed cleanup shows its Retry / Insert as-is buttons (`ignoresMouseEvents` is off only then).
private final class DictationPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a button of the (never key) pill acts at once instead of first activating the window.
private final class DictationPillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small glass pill at the top centre (under the notch when there is one) while dictation runs: the listening
/// state and the live line, or a readable notice (missing key, no field, microphone).
@MainActor
final class DictationPillController {
    let model = DictationPillModel()
    private let session: MacDictationSession
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var lastNoticeID = 0
    private static let size = NSSize(width: 460, height: 64)
    private static let failedSize = NSSize(width: 460, height: 112)
    private var size: NSSize { session.pipeline.takePhase == .failed ? Self.failedSize : Self.size }

    init(session: MacDictationSession) {
        self.session = session
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
            _ = session.phase; _ = session.noticeID; _ = session.pipeline.takePhase
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
        let takeShown = session.pipeline.takePhase != .buffering
        // Only a failed cleanup takes clicks (Retry, Insert as-is); every other state lets them through.
        panel?.ignoresMouseEvents = session.pipeline.takePhase != .failed
        if session.phase != .idle || model.notice != nil || takeShown { present() } else { hide() }
    }

    private func scheduleHide(seconds: Double = 4) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            model.notice = nil
            if session.phase == .idle, session.pipeline.takePhase == .buffering { hide() }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = session.pipeline.takePhase != .failed
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = DictationPillPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        panel.contentView = DictationPillHostingView(rootView: DictationPillView(session: session, model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = self.size
        let frame = NotchGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, height: Self.size.height)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: frame.minY - 6 + Self.size.height - size.height, width: size.width, height: size.height), display: true)
    }
}

struct DictationPillView: View {
    let session: MacDictationSession
    let model: DictationPillModel
    private var pipeline: DictationPipeline { session.pipeline }
    private static let shape = RoundedRectangle(cornerRadius: 22)

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, isActive: session.phase == .listening && model.notice == nil && pipeline.takePhase == .buffering)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        if let caption {
                            Text(caption).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundStyle(showsPlaceholder ? .secondary : .primary)
                            .lineLimit(caption == nil ? 2 : 1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsFailedActions {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Retry") { Task { await pipeline.retry() } }
                            .accessibilityIdentifier("dictation.pill.retry")
                        Button("Insert as-is") { Task { await pipeline.insertRaw() } }
                            .accessibilityIdentifier("dictation.pill.insertRaw")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: Self.shape)
            .overlay { CountdownRim(shape: Self.shape, start: pipeline.countdownStart, deadline: pipeline.countdownDeadline, lineWidth: 2) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
        .accessibilityElement(children: showsFailedActions ? .contain : .combine)
    }

    private var showsFailedActions: Bool { model.notice == nil && pipeline.takePhase == .failed }
    /// What was said so far: the take's text, then the live words.
    private var spoken: String {
        [pipeline.takeDisplay, session.tail].filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var showsPlaceholder: Bool { model.notice == nil && pipeline.takePhase == .buffering && spoken.isEmpty }
    private var symbol: String {
        if model.notice != nil || pipeline.takePhase == .failed { return "exclamationmark.triangle.fill" }
        return session.phase == .finishing || pipeline.takePhase == .cleaning ? "ellipsis" : "mic.fill"
    }
    private var tint: Color {
        if model.notice != nil || pipeline.takePhase == .failed { return .orange }
        return session.phase == .listening && pipeline.takePhase == .buffering ? .red : .secondary
    }
    /// A state line above the text: the cleanup is running, or failed and the raw text is held.
    private var caption: String? {
        guard model.notice == nil else { return nil }
        switch pipeline.takePhase {
        case .failed: return "Couldn't clean up. Your text is held."
        case .cleaning: return "Cleaning…"
        case .buffering: return nil
        }
    }
    private var line: String {
        if let notice = model.notice { return notice }
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
