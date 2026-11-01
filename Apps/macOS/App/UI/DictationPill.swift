import AppKit
import Observation
import SwiftUI
import LegatoAppServices
import LegatoMac

/// What the pill shows besides the session itself: a short notice that outlives the run.
@MainActor @Observable
final class DictationPillModel {
    var notice: String?
}

/// Never key, never main, never activating, clicks pass through: the field underneath keeps focus.
private final class DictationPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
            _ = session.phase; _ = session.noticeID
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
        if session.phase != .idle || model.notice != nil { present() } else { hide() }
    }

    private func scheduleHide(seconds: Double = 4) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            model.notice = nil
            if session.phase == .idle { hide() }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
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
        panel.contentView = NSHostingView(rootView: DictationPillView(session: session, model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = NotchGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, height: Self.size.height)
        panel.setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2, y: frame.minY - 6, width: Self.size.width, height: Self.size.height), display: true)
    }
}

struct DictationPillView: View {
    let session: MacDictationSession
    let model: DictationPillModel

    var body: some View {
        VStack {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: session.phase == .listening && model.notice == nil)
                    .frame(width: 20)
                Text(line)
                    .font(.system(size: 14))
                    .foregroundStyle(showsPlaceholder ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var showsPlaceholder: Bool { model.notice == nil && session.tail.isEmpty }
    private var symbol: String {
        if model.notice != nil { return "exclamationmark.triangle.fill" }
        return session.phase == .finishing ? "ellipsis" : "mic.fill"
    }
    private var tint: Color {
        if model.notice != nil { return .orange }
        return session.phase == .listening ? .red : .secondary
    }
    private var line: String {
        if let notice = model.notice { return notice }
        if !session.tail.isEmpty { return session.tail }
        switch session.phase {
        case .starting: return "Starting…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .idle: return ""
        }
    }
}
