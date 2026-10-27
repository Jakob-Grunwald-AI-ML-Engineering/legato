import AppKit
import Observation
import SwiftUI

/// What the floating HUD shows.
@MainActor @Observable
final class HUDModel {
    /// `cleaningUp`: the finishing step's cleanup (a language model) is running.
    enum Phase { case starting, listening, finishing, cleaningUp }

    var phase = Phase.starting
    /// Finished text (what is typed into the field, or will be).
    var committed = ""
    /// Tentative text of the phrase being spoken; shown grey.
    var volatile = ""
    /// A short message that outlives the run ("Copied to clipboard").
    var toast: String?
    /// Whether a run is showing; false while only a toast is up.
    var running = false
}

/// Never key, never main, never activating: the field underneath keeps keyboard focus.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the non-activating panel and positions it at the bottom centre of the main screen.
@MainActor
final class HUDPanelController {
    let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// A run begins: clear the text and show the panel.
    func beginRun() {
        hideTask?.cancel()
        model.committed = ""
        model.volatile = ""
        model.toast = nil
        model.phase = .starting
        model.running = true
        present()
    }

    func setPhase(_ phase: HUDModel.Phase) {
        model.phase = phase
    }

    /// The run is over; the panel disappears, or stays briefly with `toast`.
    func endRun(toast: String? = nil) {
        model.running = false
        model.volatile = ""
        guard let toast else {
            hide()
            return
        }
        show(toast: toast)
    }

    func show(toast: String, for seconds: Double = 3) {
        hideTask?.cancel()
        model.toast = toast
        present()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.model.running else { return }
            self.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        model.toast = nil
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
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
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48))
    }
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.running { runCard }
            if let toast = model.toast { toastCard(toast) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 12)
    }

    private var runCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(model.phase == .listening ? Color.red : Color.secondary)
                .symbolEffect(.pulse, isActive: model.phase == .listening || model.phase == .cleaningUp)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if model.committed.isEmpty, model.volatile.isEmpty {
                        Text(phaseText).foregroundStyle(.secondary)
                    } else {
                        Text(transcript)
                    }
                }
                .font(.system(size: 15))
                .lineLimit(5)
                .truncationMode(.head)
                if model.phase == .cleaningUp, !(model.committed.isEmpty && model.volatile.isEmpty) {
                    Text("Cleaning up…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var symbol: String {
        switch model.phase {
        case .finishing: "ellipsis"
        case .cleaningUp: "sparkles"
        case .starting, .listening: "mic.fill"
        }
    }

    private var phaseText: String {
        switch model.phase {
        case .starting: "Starting…"
        case .listening: "Listening…"
        case .finishing: "Finishing…"
        case .cleaningUp: "Cleaning up…"
        }
    }

    private func toastCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    /// Committed text in the primary colour, tentative text grey.
    private var transcript: AttributedString {
        var committed = AttributedString(tail(model.committed))
        committed.foregroundColor = .primary
        var volatile = AttributedString(model.volatile)
        volatile.foregroundColor = .secondary
        return committed + volatile
    }

    /// Long dictations show their end.
    private func tail(_ text: String) -> String {
        text.count > 400 ? "…" + text.suffix(400) : text
    }
}
