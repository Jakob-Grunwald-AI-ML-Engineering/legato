#if LEGATO_INTERNAL
import AudioToolbox
import SwiftUI
import UIKit
import UserNotifications

/// What the debug bridge shows Jakob: messages from whoever runs ctl.sh, questions with buttons, a status banner.
/// Internal builds only. The text is whatever the operator sent; dictated text appears only if the operator's
/// message contains it.
@MainActor @Observable
final class DebugMessages {
    static let shared = DebugMessages()

    struct Item: Identifiable, Equatable {
        let id: String
        let text: String
        /// Empty for `say` (a single dismiss button).
        let choices: [String]
    }

    private(set) var queue: [Item] = []
    private(set) var status: String?
    @ObservationIgnored private var timeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var limits: [String: Double] = [:]
    @ObservationIgnored private var window: DebugOverlayWindow?

    var current: Item? { queue.first }

    /// Frames (window coordinates) of the banner and the card: the only places the overlay takes touches.
    @ObservationIgnored private(set) var interactiveRects: [String: CGRect] = [:]
    func setRect(_ key: String, _ rect: CGRect?) { interactiveRects[key] = rect }

    /// Window-level check for `overlay-selftest`: does a touch at `point` reach the overlay?
    func overlayHit(at point: CGPoint) -> Bool { window?.hitTest(point, with: nil) != nil }
    var firstRect: CGRect? { interactiveRects["card"] ?? interactiveRects["status"] }

    /// Parsed `ask`/`say` arguments: the text, the choices, `--timeout <s>` and `--sound`.
    struct Parsed: Equatable {
        var text: String
        var choices: [String]
        var timeout: Double?
        var sound = false
    }

    static func parse(_ args: [String], takesChoices: Bool) -> Parsed? {
        var rest: [String] = []
        var timeout: Double?
        var sound = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--timeout":
                guard i + 1 < args.count, let t = Double(args[i + 1]), t > 0 else { return nil }
                timeout = t
                i += 1
            case "--sound": sound = true
            default: rest.append(args[i])
            }
            i += 1
        }
        guard let text = rest.first, !text.isEmpty else { return nil }
        let choices = takesChoices ? Array(rest.dropFirst()) : []
        if takesChoices && choices.isEmpty { return nil }
        return Parsed(text: text, choices: choices, timeout: timeout, sound: sound)
    }

    func say(id: String, text: String) { enqueue(Item(id: id, text: text, choices: [])) }

    func ask(id: String, text: String, choices: [String], timeout: Double?, sound: Bool) {
        enqueue(Item(id: id, text: text, choices: choices))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if sound { AudioServicesPlaySystemSound(1007) }
        if UIApplication.shared.applicationState != .active { notify(id: id, text: text) }
        if let timeout { limits[id] = timeout }
        startTimer()
    }

    /// An ask's timeout runs while it is on screen, not while it waits behind other messages.
    private func startTimer() {
        guard let id = current?.id, timeouts[id] == nil, let limit = limits[id] else { return }
        timeouts[id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled { reply(id: id, choice: "timeout") }
        }
    }

    func setStatus(_ text: String?) {
        status = (text?.isEmpty ?? true) ? nil : text
        refreshWindow()
    }

    func clear() {
        for item in queue where !item.choices.isEmpty { DebugBridge.emit(id: item.id, event: "reply", ["choice": "cleared"]) }
        queue = []
        status = nil
        timeouts.values.forEach { $0.cancel() }
        timeouts = [:]
        limits = [:]
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        refreshWindow()
    }

    /// Jakob tapped a button (or the ask timed out).
    func reply(id: String, choice: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue.remove(at: index)
        timeouts.removeValue(forKey: id)?.cancel()
        limits[id] = nil
        DebugBridge.emit(id: id, event: item.choices.isEmpty ? "dismissed" : "reply", ["choice": choice])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        startTimer()
        refreshWindow()
    }

    private func enqueue(_ item: Item) {
        queue.append(item)
        refreshWindow()
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
        let visible = current != nil || status != nil
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
        guard DebugMessages.shared.interactiveRects.values.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
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
