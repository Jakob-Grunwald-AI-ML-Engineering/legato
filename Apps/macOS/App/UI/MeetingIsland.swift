import AppKit
import Observation
import SwiftUI
import LegatoMac
import LegatoMeetings

/// Never key, never main, never activating: the app underneath keeps focus. It takes clicks (the pill, Stop).
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
    /// The full card (title, Stop, detail) rather than the pill.
    var expanded = false
    /// Drawn at all; false only while it fades out.
    var shown = true
    var compactSize = CGSize(width: 112, height: 30)
    var fullSize = CGSize(width: 400, height: 68)
}

/// The island of a recording meeting. While recording it rests as a small pill (a red dot and the time; hugging the notch
/// with a wing on each side, or a small card at the top centre without one) so it never covers the Meetings toolbar.
/// It opens to the full card with Stop for a few seconds when the meeting starts, when the pill is clicked, and when
/// something must not be missed (a warning, a refused hotkey, a failed start); `IslandExpansion` decides when it goes back.
///
/// The window is the size of what is shown: the pill's, or the card's while the card is open or closing, so the empty part
/// never takes clicks. Motion is its own (`animationBehavior = .none`); `NotchPanelController` is not involved.
@MainActor
final class MeetingIslandController {
    private let controller: MeetingController
    private let model = MeetingIslandModel()
    private let presentation = IslandPresentation()
    private var panel: NSPanel?
    private var expansion = IslandExpansion()
    private var lastPhase = MeetingController.Phase.idle
    private var lastNotice: String?
    private var lastWarning: String?
    private var tickTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private static let wing: CGFloat = 52
    private static let cardSize = CGSize(width: 400, height: 68)

    init(controller: MeetingController) {
        self.controller = controller
        track()
        update()
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func track() {
        withObservationTracking {
            _ = controller.phase; _ = controller.notice; _ = controller.liveWarning
        } onChange: { [weak self] in
            Task { @MainActor in self?.update(); self?.track() }
        }
    }

    private func update() {
        let phase = controller.phase, notice = controller.notice, warning = controller.liveWarning
        defer { (lastPhase, lastNotice, lastWarning) = (phase, notice, warning) }
        if phase == .recording, lastPhase != .recording { expansion.recordingStarted(at: now()) }
        if phase != .recording { expansion.reset() }
        // A new notice or warning opens the card for a while; a failed start stays open until it is read.
        if let notice, notice != lastNotice { expansion.attention(at: now()) }
        if let warning, warning != lastWarning { expansion.attention(at: now()) }
        guard phase != .idle || notice != nil else { hide(); return }
        present()
    }

    // MARK: Showing

    /// The card shows whenever it is not a recording at rest: starting, saving, a notice with no meeting.
    private var wantsCard: Bool {
        controller.phase != .recording || expansion.isExpanded || (controller.noticeIsSticky && controller.notice != nil)
    }

    private func present() {
        hideTask?.cancel(); hideTask = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let first = !panel.isVisible
        refreshSizes()
        applyExpansion(initial: first)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        if first { withAnimation(.easeOut(duration: 0.2)) { model.shown = true } }
        startTicking()
    }

    private func hide() {
        guard let panel, panel.isVisible, hideTask == nil else { return }
        stopMonitoring()
        tickTask?.cancel(); tickTask = nil
        panel.ignoresMouseEvents = true
        withAnimation(.easeIn(duration: 0.2)) { model.shown = false }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self else { return }
            hideTask = nil
            panel.orderOut(nil)
            model.expanded = false
        }
    }

    /// Opens or closes the card. The window grows first and shrinks last, so the motion is always inside it.
    private func applyExpansion(initial: Bool = false) {
        guard let panel else { return }
        let card = wantsCard
        shrinkTask?.cancel(); shrinkTask = nil
        if card {
            setFrame(panel, compact: false)
            if initial { model.expanded = true } else { withAnimation(NotchIslandTokens.spring) { model.expanded = true } }
            if controller.phase == .recording { startMonitoring() }
        } else {
            if initial {
                model.expanded = false
                setFrame(panel, compact: true)
            } else {
                withAnimation(NotchIslandTokens.spring) { model.expanded = false }
                shrinkTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(NotchIslandTokens.closeDuration + 0.05))
                    guard !Task.isCancelled, let self, let panel = self.panel else { return }
                    setFrame(panel, compact: true)
                }
            }
            stopMonitoring()
        }
    }

    /// The window sizes of the two states (with the shoulders and the safe-area band on a notch).
    private func refreshSizes() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let style = NotchIslandStyle(screen: screen)
        if model.style != style { model.style = style }
        let card = Self.cardSize
        if style.attached {
            // The pill is the menu-bar band: the notch and a wing each side.
            model.compactSize = CGSize(width: style.notchWidth + 2 * Self.wing + 2 * style.shoulder, height: style.safeTop)
            model.fullSize = CGSize(width: card.width + 2 * style.shoulder, height: card.height + style.safeTop)
        } else {
            model.compactSize = CGSize(width: 112, height: 30)
            model.fullSize = card
        }
    }

    private func setFrame(_ panel: NSPanel, compact: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let style = model.style
        let size = compact ? model.compactSize : model.fullSize
        // Card dimensions without the shoulders and the band, which `NotchGeometry.island` adds.
        let card = CGSize(width: size.width - 2 * style.shoulder, height: size.height - style.safeTop)
        var frame = NotchGeometry.island(screen: screen.frame, visible: screen.visibleFrame, safeTop: style.safeTop,
                                         width: card.width, height: card.height)
        if !style.attached { frame.origin.y -= 6 }
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = MeetingIslandPanel(contentRect: NSRect(origin: .zero, size: Self.cardSize),
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
        panel.contentView = MeetingIslandHostingView(rootView: MeetingIslandView(
            controller: controller, model: model, pillClicked: { [weak self] in self?.pillClicked() },
            cardClicked: { [weak self] in self?.cardClicked() }))
        return panel
    }

    // MARK: Interaction

    private func pillClicked() {
        expansion.clicked(at: now())
        applyExpansion()
        startTicking()
    }

    /// A click on the card, not on Stop: a failed start is read; otherwise the card goes back to the pill.
    private func cardClicked() {
        if controller.noticeIsSticky { controller.dismissNotice(); return }
        guard controller.phase == .recording else { return }
        expansion.clickedOutside()
        applyExpansion()
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let before = wantsCard
                expansion.tick(at: now())
                if wantsCard != before { applyExpansion() }
            }
        }
    }

    /// While the card is open a click anywhere else closes it.
    private func startMonitoring() {
        guard monitors.isEmpty else { return }
        let outside: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.controller.phase == .recording, !self.controller.noticeIsSticky else { return }
                self.expansion.clickedOutside()
                self.applyExpansion()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) { monitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { outside(event) }
            return event
        }
        if let local { monitors.append(local) }
    }

    private func stopMonitoring() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}

private struct MeetingIslandView: View {
    let controller: MeetingController
    let model: MeetingIslandModel
    let pillClicked: () -> Void
    let cardClicked: () -> Void

    var body: some View {
        let size = model.expanded ? model.fullSize : model.compactSize
        let shape = NotchIslandShape(shoulder: model.style.shoulder)
        ZStack(alignment: .top) {
            if model.expanded { card.transition(.opacity) } else { pill.transition(.opacity) }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(NotchIslandTokens.surface, in: shape)
        .overlay { if !model.style.attached { shape.stroke(.white.opacity(0.1), lineWidth: 0.5) } }
        .clipShape(shape)
        .contentShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(model.shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    // MARK: Pill

    /// A red dot and the time. On a notch the dot sits in the left wing and the time in the right one.
    @ViewBuilder private var pill: some View {
        let dot = Circle().fill(warning ? Color.orange : Color.red).frame(width: 8, height: 8)
            .opacity(controller.phase == .recording ? 1 : 0.6)
        let time = Text(MeetingListLogic.clock(controller.elapsed)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
        Group {
            if model.style.attached {
                HStack(spacing: 0) {
                    dot.frame(maxWidth: .infinity)
                    Color.clear.frame(width: model.style.notchWidth)
                    time.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, model.style.shoulder)
            } else {
                HStack(spacing: 8) { dot; time }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: pillClicked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording meeting \(MeetingListLogic.clock(controller.elapsed))")
        .accessibilityHint("Shows the meeting controls")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, pillClicked)
        .accessibilityIdentifier("meeting.island.pill")
    }

    private var warning: Bool { controller.liveWarning != nil }

    // MARK: Card

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
        .padding(.top, model.style.topInset)
        .padding(.horizontal, model.style.shoulder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: cardClicked)
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
