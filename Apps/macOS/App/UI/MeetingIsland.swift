import AppKit
import Observation
import SwiftUI
import LegatoMac
import LegatoMeetings

/// Never key, never main, never activating: the app underneath keeps focus. It takes clicks for Stop.
private final class MeetingIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class MeetingIslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor @Observable
private final class MeetingIslandModel {
    var style = NotchIslandStyle.detached
}

/// The island that grows out of the notch (a top-centre card without one) while a meeting records or starts, and for a
/// few seconds after a notice: a refused hotkey, a start that failed. It shows the time and the state of the capture,
/// and stops the meeting.
@MainActor
final class MeetingIslandController {
    private let controller: MeetingController
    private let model = MeetingIslandModel()
    private let presentation = IslandPresentation()
    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?
    private var presentGeneration = 0
    private static let size = NSSize(width: 400, height: 68)

    init(controller: MeetingController) {
        self.controller = controller
        track()
        update()
    }

    private func track() {
        withObservationTracking {
            _ = controller.phase; _ = controller.notice
        } onChange: { [weak self] in
            Task { @MainActor in self?.update(); self?.track() }
        }
    }

    private func update() {
        if controller.phase != .idle || controller.notice != nil { present() } else { hide() }
    }

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
        panel.ignoresMouseEvents = false
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
        let panel = MeetingIslandPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = MeetingIslandHostingView(rootView: MeetingIslandView(controller: controller, model: model, presentation: presentation))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let style = NotchIslandStyle(screen: screen)
        var frame = NotchGeometry.island(screen: screen.frame, visible: screen.visibleFrame, safeTop: style.safeTop,
                                         width: Self.size.width, height: Self.size.height)
        if !style.attached { frame.origin.y -= 6 }
        if model.style != style { model.style = style }
        panel.setFrame(frame, display: true)
    }
}

private struct MeetingIslandView: View {
    let controller: MeetingController
    let model: MeetingIslandModel
    let presentation: IslandPresentation

    var body: some View {
        NotchIsland(style: model.style, presentation: presentation) { card }
            .accessibilityElement(children: .contain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: controller.phase == .recording && controller.notice == nil)
                    .frame(width: 20)
                Text(title).font(NotchIslandTokens.title)
                if controller.phase == .recording {
                    Text(MeetingListLogic.clock(controller.elapsed)).font(NotchIslandTokens.title.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if controller.phase == .recording {
                    StopButton { controller.stop() }
                        .accessibilityIdentifier("meeting.island.stop")
                }
            }
            Text(detail)
                .font(NotchIslandTokens.caption)
                .foregroundStyle(detailIsWarning ? Color.orange : Color.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        switch controller.phase {
        case .idle: "Meeting"
        case .starting: "Starting meeting…"
        case .recording: "Recording meeting"
        case .stopping: "Saving meeting…"
        }
    }
    private var symbol: String { controller.phase == .idle ? "exclamationmark.triangle.fill" : "record.circle.fill" }
    private var tint: Color { controller.phase == .idle ? .orange : .red }
    private var detailIsWarning: Bool { controller.notice != nil || controller.liveWarning != nil }
    private var detail: String {
        controller.notice ?? controller.liveWarning
            ?? (controller.phase == .recording ? "Microphone and system audio, with speakers" : "Opening the microphone and the system audio")
    }
}

/// The red Stop of a recording: the island and the window's toolbar capsule share it.
struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Stop")
                .font(.caption.weight(.semibold))
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop meeting")
        .accessibilityAction(.default, action)
    }
}
