import AppKit
import Observation
import SwiftUI
import LegatoMac

/// Never key, never main, never activating: the app underneath keeps focus. It takes clicks (Record, Not now).
private final class CallPromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class CallPromptHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor @Observable
private final class CallPromptModel {
    var style = NotchIslandStyle.detached
    var appName = ""
    var shown = false
}

/// The small card that offers to record a call: the app's name, Record and Not now. It sits where the meeting island
/// sits, in the same look, and goes away by itself after `lifetime`, when the user answers, or when something else
/// takes over (`hide()`). Independent of `NotchPanelController`; like the island it keeps `animationBehavior = .none`.
@MainActor
final class CallPromptController {
    private static let lifetime: Duration = .seconds(20)
    private static let cardSize = CGSize(width: 400, height: 68)
    private let model = CallPromptModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    /// The user chose Record.
    var onRecord: () -> Void = {}

    func show(appName: String) {
        model.appName = appName
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.2)) { model.shown = true }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Instant, with no fade: whatever comes next (a meeting island, the composer) takes the place at once.
    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }
        model.shown = false
        panel.orderOut(nil)
    }

    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let style = NotchIslandStyle(screen: screen)
        model.style = style
        var frame = NotchGeometry.island(screen: screen.frame, visible: screen.visibleFrame, safeTop: style.safeTop,
                                         width: Self.cardSize.width, height: Self.cardSize.height)
        if !style.attached { frame.origin.y -= 6 }
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = CallPromptPanel(contentRect: NSRect(origin: .zero, size: Self.cardSize),
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
        panel.contentView = CallPromptHostingView(rootView: CallPromptView(
            model: model, record: { [weak self] in self?.hide(); self?.onRecord() }, dismiss: { [weak self] in self?.hide() }))
        return panel
    }
}

private struct CallPromptView: View {
    let model: CallPromptModel
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let shape = NotchIslandShape(shoulder: model.style.shoulder)
        card
            .background(NotchIslandTokens.surface, in: shape)
            .overlay { if !model.style.attached { shape.stroke(.white.opacity(0.1), lineWidth: 0.5) } }
            .clipShape(shape)
            .contentShape(shape)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(model.shown ? 1 : 0)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
    }

    private var card: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill").foregroundStyle(.green).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.appName) is on a call").font(NotchIslandTokens.title).lineLimit(1)
                Text("Record it as a meeting?").font(NotchIslandTokens.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Not now", action: dismiss)
                .buttonStyle(.plain).font(NotchIslandTokens.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("call.prompt.dismiss")
            Button(action: record) {
                Text("Record").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4).background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.prompt.record")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.top, model.style.topInset)
        .padding(.horizontal, model.style.shoulder)
        .frame(width: 400 + 2 * model.style.shoulder, height: 68 + model.style.safeTop, alignment: .top)
    }
}
