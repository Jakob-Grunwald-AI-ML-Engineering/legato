#if LEGATO_INTERNAL
import AudioToolbox
import SwiftUI
import LegatoDevHarness
import UIKit
import UserNotifications

/// What the debug bridge shows Jakob: messages from whoever runs ctl.sh, questions with buttons, a status banner.
/// Internal builds only. The text is whatever the operator sent; dictated text appears only if the operator's
/// message contains it.
@MainActor @Observable
final class DebugMessages {
    static let shared = DebugMessages()

    typealias Item = LegatoDevHarness.DebugMessages.Item
    typealias Parsed = LegatoDevHarness.DebugMessages.Parsed
    private let state: LegatoDevHarness.DebugMessages
    @ObservationIgnored private var window: DebugOverlayWindow?
    @ObservationIgnored private var visibleCardID: String?
    @ObservationIgnored private(set) var interactiveRects: [String: CGRect] = [:]

    private init() {
        state = LegatoDevHarness.DebugMessages { id, event, fields in
            DebugBridge.emit(id: id, event: event, fields)
            if event == "reply" || event == "dismissed" {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
        state.onChange = { [weak self] in self?.refreshWindow() }
    }

    var queue: [Item] { state.queue }
    var status: String? { state.status }
    var blocking: Bool { state.blocking }
    var current: Item? { state.current }
    func setRect(_ key: String, _ rect: CGRect?) { interactiveRects[key] = rect }
    func overlayHit(at point: CGPoint) -> Bool { window?.hitTest(point, with: nil) != nil }
    var firstRect: CGRect? { interactiveRects["card"] ?? interactiveRects["status"] }

    static func parse(_ args: [String], takesChoices: Bool) -> Parsed? {
        LegatoDevHarness.DebugMessages.parse(args, takesChoices: takesChoices)
    }
    func say(id: String, text: String) { state.say(id: id, text: text) }
    func ask(id: String, text: String, choices: [String], timeout: Double?, sound: Bool) {
        state.ask(id: id, text: text, choices: choices, timeout: timeout)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if sound { AudioServicesPlaySystemSound(1007) }
        if UIApplication.shared.applicationState != .active { notify(id: id, text: text) }
    }
    func setStatus(_ text: String?) { state.setStatus(text) }
    func setBlocking(_ on: Bool) { state.setBlocking(on) }
    func clear() {
        state.clear()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    func reply(id: String, choice: String) { state.reply(id: id, choice: choice) }

    func cardAppeared(id: String) { visibleCardID = id; reportPresentation() }
    func cardDisappeared(id: String) { if visibleCardID == id { visibleCardID = nil } }
    func reportPresentation() {
        guard UIApplication.shared.applicationState == .active, window?.isHidden == false else { return }
        state.presented(id: visibleCardID)
    }

    /// Local notification so an `ask` is seen while the app is in the background; asks for permission on first use.
    private func notify(id: String, text: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Debug: an answer is needed"
            content.body = text
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private func refreshWindow() {
        let visible = current != nil || status != nil || blocking
        if visible, window == nil,
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
               .first(where: { $0.activationState == .foregroundActive }) ??
               UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let w = DebugOverlayWindow(windowScene: scene)
            w.windowLevel = .alert + 1
            w.backgroundColor = .clear
            let host = UIHostingController(rootView: DebugOverlayView(messages: self))
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.isHidden = !visible
    }
}

/// Passes touches through everywhere except the banner and the card.
final class DebugOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // SwiftUI's hosting view is the hit view even over its buttons, so the hit view cannot tell controls from
        // empty space: decide by the frames the overlay reports, then let super route the touch.
        let messages = DebugMessages.shared
        guard messages.blocking || messages.interactiveRects.values.contains(where: { $0.contains(point) }) else { return nil }
        // Blocking: a tap off the controls lands on the hosting view and goes no further (not to the app).
        return super.hitTest(point, with: event) ?? rootViewController?.view
    }
}

private struct DebugBadge: View {
    var body: some View {
        Text("DEBUG")
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange, in: Capsule())
            .foregroundStyle(.black)
            .accessibilityHidden(true)
    }
}

struct DebugOverlayView: View {
    var messages: DebugMessages

    var body: some View {
        ZStack(alignment: .top) {
            if messages.blocking {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .overlay(alignment: .bottom) {
                        Text("Debug mode: taps on the app are blocked.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(Color.black.opacity(0.85), in: Capsule())
                            .padding(.bottom, 40)
                    }
                    .accessibilityLabel("Debug mode: taps are blocked")
            }
            content
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            messages.reportPresentation()
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            if let status = messages.status {
                HStack(spacing: 8) {
                    DebugBadge()
                    Text(status).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Debug status: \(status)")
                .reportFrame("status", to: messages)
            }
            if let item = messages.current {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        DebugBadge()
                        if messages.queue.count > 1 {
                            Text("1 of \(messages.queue.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(item.text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        ForEach(item.choices.isEmpty ? ["OK"] : item.choices, id: \.self) { choice in
                            Button(choice) { messages.reply(id: item.id, choice: choice) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .accessibilityLabel(item.choices.isEmpty ? "Dismiss debug message" : "Answer: \(choice)")
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange, lineWidth: 3))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Debug message: \(item.text)")
                .reportFrame("card", to: messages)
                .id(item.id)
                .onChange(of: item.id, initial: true) { _, id in messages.cardAppeared(id: id) }
                .onDisappear { messages.cardDisappeared(id: item.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

private extension View {
    /// Publishes this view's frame in window coordinates so the window can tell its controls from empty space.
    func reportFrame(_ key: String, to messages: DebugMessages) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { messages.setRect(key, $0) }
            .onDisappear { messages.setRect(key, nil) }
    }
}
#endif
