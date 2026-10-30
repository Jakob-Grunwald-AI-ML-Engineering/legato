#if LEGATO_INTERNAL
import AppKit
import LegatoDevHarness
import Observation
import SwiftUI

/// AppKit presentation only; the queue, replies and timers belong to LegatoDevHarness.
@MainActor @Observable final class DebugMessages {
    static let shared = DebugMessages()
    typealias Item = LegatoDevHarness.DebugMessages.Item
    private let state: LegatoDevHarness.DebugMessages
    @ObservationIgnored private var panel: DebugPanel?
    @ObservationIgnored private var visibleCardID: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var shields: [ObjectIdentifier: ShieldRecord] = [:]

    private init() {
        state = LegatoDevHarness.DebugMessages { id, event, fields in DebugBridge.emit(id: id, event: event, fields) }
        state.onChange = { [weak self] in self?.refresh() }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncShields(); self?.reportPresentation() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            let key = ObjectIdentifier(window)
            MainActor.assumeIsolated { self?.shields.removeValue(forKey: key)?.view.removeFromSuperview() }
        })
        // Local monitors see only this process's events; other apps retain all mouse and keyboard input.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .scrollWheel,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            let swallow = MainActor.assumeIsolated {
                guard let self, self.state.blocking else { return false }
                if event.window === self.panel { return false }
                return event.window != nil || NSApp.isActive
            }
            return swallow ? nil : event
        }
    }

    var current: Item? { state.current }
    var queue: [Item] { state.queue }
    var status: String? { state.status }
    var blocking: Bool { state.blocking }
    var debugSnapshot: [String: Any] {
        ["queued": queue.count, "currentID": current?.id as Any? ?? NSNull(),
         "choices": current?.choices.count ?? 0, "statusChars": status?.count ?? 0,
         "blocking": blocking, "panelVisible": panel?.isVisible == true,
         "shieldedWindows": shields.count]
    }
    func say(id: String, text: String) { state.say(id: id, text: text) }
    func ask(id: String, text: String, choices: [String], timeout: Double?, sound: Bool) {
        state.ask(id: id, text: text, choices: choices, timeout: timeout)
        if sound { NSSound.beep() }
    }
    func reply(id: String, choice: String) { state.reply(id: id, choice: choice) }
    func setStatus(_ text: String?) { state.setStatus(text) }
    func setBlocking(_ on: Bool) { state.setBlocking(on) }
    func clear() { state.clear() }
    func cardAppeared(id: String) { visibleCardID = id; reportPresentation() }
    func cardDisappeared(id: String) { if visibleCardID == id { visibleCardID = nil } }
    func reportPresentation() {
        guard let panel, panel.isVisible, panel.occlusionState.contains(.visible) else { return }
        state.presented(id: visibleCardID)
    }
    func resize(_ size: CGSize) {
        guard let panel, size.height.isFinite, size.height > 0 else { return }
        let wanted = NSSize(width: 500, height: max(52, size.height))
        if abs(panel.contentLayoutRect.height - wanted.height) > 0.5 { panel.setContentSize(wanted); position(panel) }
    }
    private func refresh() {
        syncShields()
        let visible = current != nil || status != nil || blocking
        guard visible else { panel?.orderOut(nil); visibleCardID = nil; return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = current == nil
        position(panel)
        panel.orderFrontRegardless()
        reportPresentation()
    }
    private func makePanel() -> DebugPanel {
        let panel = DebugPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Legato Debug"
        panel.identifier = NSUserInterfaceItemIdentifier("legato-debug-overlay")
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        let host = DebugHostingView(rootView: DebugOverlayView(messages: self))
        panel.contentView = host
        let preferred = host.fittingSize
        if preferred.height.isFinite, preferred.height > 0 {
            panel.setContentSize(NSSize(width: 500, height: max(52, preferred.height)))
        }
        return panel
    }
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let rect = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: rect.midX - panel.frame.width / 2, y: rect.maxY - panel.frame.height - 24))
    }
    private func syncShields() {
        guard blocking else {
            for record in shields.values { record.view.removeFromSuperview() }
            shields = [:]
            return
        }
        for (key, record) in shields where record.window?.isVisible != true {
            record.view.removeFromSuperview(); shields[key] = nil
        }
        for window in NSApp.windows where window !== panel && window.isVisible {
            guard let content = window.contentView else { continue }
            let key = ObjectIdentifier(window)
            if let record = shields[key], record.view.superview === content { continue }
            shields[key]?.view.removeFromSuperview()
            let shield = DebugShield(frame: content.bounds)
            shield.autoresizingMask = [.width, .height]
            content.addSubview(shield, positioned: .above, relativeTo: nil)
            shields[key] = ShieldRecord(window: window, view: shield)
        }
    }
}

/// Mouse controls work without making this panel key or stealing another application's keyboard focus.
private final class DebugPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class DebugHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
@MainActor private final class ShieldRecord {
    weak var window: NSWindow?
    let view: DebugShield
    init(window: NSWindow, view: DebugShield) { self.window = window; self.view = view }
}
private final class DebugShield: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("legato-debug-block")
        setAccessibilityLabel("Debug mode: app input is blocked")
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        let text = "DEBUG: app input is blocked"
        let style = NSMutableParagraphStyle(); style.alignment = .center
        text.draw(in: NSRect(x: 8, y: 14, width: bounds.width - 16, height: 20), withAttributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .paragraphStyle: style])
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

private struct DebugOverlayView: View {
    var messages: DebugMessages
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = messages.status {
                HStack(spacing: 10) {
                    badge
                    Text(status).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("legato-debug-status")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if let item = messages.current {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        badge
                        if messages.queue.count > 1 { Text("1 of \(messages.queue.count)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(item.text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("legato-debug-message-text")
                    HStack {
                        ForEach(Array((item.choices.isEmpty ? ["OK"] : item.choices).enumerated()), id: \.offset) { index, choice in
                            Button(choice) { messages.reply(id: item.id, choice: choice) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .accessibilityLabel(item.choices.isEmpty ? "Dismiss debug message" : "Answer: \(choice)")
                                .accessibilityIdentifier(item.choices.isEmpty ? "legato-debug-dismiss" : "legato-debug-answer-\(index)")
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange, lineWidth: 3))
                .id(item.id)
                .onChange(of: item.id, initial: true) { _, id in messages.cardAppeared(id: id) }
                .onDisappear { messages.cardDisappeared(id: item.id) }
            }
            if messages.blocking, messages.current == nil, messages.status == nil {
                HStack { badge; Text("App input is blocked.").font(.subheadline.weight(.semibold)) }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(6)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legato-debug-overlay")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { messages.resize($0) }
    }
    private var badge: some View {
        Text("DEBUG").font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange, in: Capsule()).foregroundStyle(.black).accessibilityHidden(true)
    }
}
#endif
