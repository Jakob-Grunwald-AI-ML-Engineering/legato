#if DEBUG
import Foundation
import LegatoKeyboardCore

/// Stands in for the keyboard extension in the simulator end-to-end run, over the same App Group
/// values and Darwin notes: it publishes presence, sends requests (and the URL the Link would open),
/// and applies the streamed text to an in-memory document through the real `TypewriterReveal` (ticked like
/// the keyboard's, so the text arrives progressively),
/// reporting `link.applied`. Debug builds only.
@MainActor
final class E2EFakeKeyboard {
    static let shared = E2EFakeKeyboard()

    /// The field's text; the cursor is at its end.
    private(set) var document = ""
    /// Whether streamed text is typed and confirmed. NO simulates a keyboard that never reports back.
    var applies = true

    private let documentID = "e2e-document"
    private let store: LinkStore? = UserDefaultsLinkStore().map(LinkStore.init)
    private var cursor: AppliedCursor?
    private var reveal = TypewriterReveal()
    private var ticker: Task<Void, Never>?
    /// Same cadence as `KeyboardController.tickInterval`.
    private static let tickInterval = Duration.milliseconds(33)
    private var visible = false
    private var presenceTask: Task<Void, Never>?
    private var observers: [DarwinObserver] = []
    private var requestCount = 0

    func run(_ command: String) async {
        installObservers()
        switch command {
        case "kbd-visible": setVisible(true)
        case "kbd-hidden": setVisible(false)
        case "kbd-request-start": await send(.start)
        case "kbd-request-stop": await send(.stop)
        case "kbd-request-end-keep-alive": await send(.endKeepAlive)
        case "kbd-hop-arm": await hop(urlFirst: false)
        case "kbd-hop-start": await hop(.start, urlFirst: false)
        case "kbd-hop-arm-url-first": await hop(urlFirst: true)
        case "kbd-forged-url": await forgedURL()
        default: E2E.log("kbd.unknown \(command)")
        }
    }

    // MARK: Presence

    private func setVisible(_ value: Bool) {
        visible = value
        presenceTask?.cancel()
        presenceTask = nil
        writePresence()
        E2E.log("kbd.visible value=\(value ? 1 : 0)")
        guard value else { return }
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LinkChannel.presenceInterval))
                guard !Task.isCancelled else { return }
                self?.writePresence()
            }
        }
    }

    private func writePresence() {
        store?.write(KeyboardPresence(visible: visible, at: Date()), forKey: LinkChannel.Key.presence)
        DarwinObserver.post(LinkChannel.Note.presence)
    }

    // MARK: Requests

    private func newID() -> String {
        requestCount += 1
        return UUID().uuidString
    }

    /// What the mic key does in `.remote` mode: the request, then wait for the ack.
    private func send(_ command: RequestCommand, id: String? = nil) async {
        let id = id ?? newID()
        post(command, id: id)
        await awaitAck(id)
    }

    private func post(_ command: RequestCommand, id: String) {
        writeRequest(command, id: id)
        DarwinObserver.post(LinkChannel.Note.request)
    }

    private func writeRequest(_ command: RequestCommand, id: String) {
        store?.write(KeyboardRequest(id: id, command: command, at: Date()), forKey: LinkChannel.Key.request)
        E2E.log("kbd.request command=\(command.rawValue)")
    }

    private func awaitAck(_ id: String) async {
        let deadline = ContinuousClock.now + .seconds(LinkChannel.ackTimeout)
        while ContinuousClock.now < deadline {
            if let ack = store?.read(KeyboardAck.self, forKey: LinkChannel.Key.ack), ack.id == id {
                E2E.log("kbd.ack result=\(ack.result.rawValue)")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        E2E.log("kbd.ack result=timeout")
    }

    /// What the mic key does in `.openApp` mode: the Darwin request and the URL the Link opens. By default
    /// both ask only to arm the microphone; `kbd-hop-start` is a start the host could not take over the link
    /// (it answered `hop`), whose URL then reaches the app.
    private func hop(_ command: RequestCommand = .arm, urlFirst: Bool) async {
        let id = newID()
        let url = KeyboardURL.make(command: command, requestID: id)
        if urlFirst {
            // The Link tap writes the request as it opens the URL; the Darwin note comes after the app is up.
            writeRequest(command, id: id)
            await AppController.shared.handle(url)
            DarwinObserver.post(LinkChannel.Note.request)
        } else {
            post(command, id: id)
            await AppController.shared.handle(url)
        }
        await awaitAck(id)
    }

    /// A `legato://keyboard?cmd=arm` URL that no keyboard request backs (a web page, another app): the app
    /// may open, but must not arm the microphone.
    private func forgedURL() async {
        await AppController.shared.handle(KeyboardURL.make(command: .arm, requestID: UUID().uuidString))
        E2E.log("kbd.forged-url handled")
    }

    // MARK: Applying the host's text

    private func installObservers() {
        guard observers.isEmpty else { return }
        observers = [
            DarwinObserver(name: LinkChannel.Note.host) {
                Task { @MainActor in E2EFakeKeyboard.shared.hostDidChange() }
            },
        ]
    }

    private func hostDidChange() { applyHost() }

    /// Mirrors `KeyboardController.applyHost`: a host update moves the reveal's target, the ticker (with
    /// `elapsedMs`, the time since its last tick) reveals it.
    private func applyHost(elapsedMs: Double = 0) {
        guard visible, applies, let store,
              let state = store.read(HostState.self, forKey: LinkChannel.Key.host)
        else { return stopTicker() }
        let before = cursor
        let plan = reveal.plan(
            state: state, cursor: cursor, contextBefore: document, documentID: documentID,
            animated: true, elapsedMs: elapsedMs)
        for op in plan.ops {
            switch op {
            case .deleteBackward(let count): document.removeLast(min(count, document.count))
            case .insert(let text): document += text
            }
        }
        cursor = plan.cursor
        startTickerIfNeeded()
        if elapsedMs > 0, !plan.ops.isEmpty { E2E.log("kbd.reveal tick") }
        guard plan.cursor != before || !plan.ops.isEmpty, let applied = plan.cursor,
              !plan.ops.isEmpty || applied.finalApplied else { return }
        store.write(applied, forKey: LinkChannel.Key.applied)
        DarwinObserver.post(LinkChannel.Note.applied)
        E2E.log("kbd.apply final=\(applied.finalApplied ? 1 : 0) doc=\(E2E.quote(document))")
    }

    private func startTickerIfNeeded() {
        guard reveal.needsTicks, visible else { return stopTicker() }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                let now = clock.now
                let parts = last.duration(to: now).components
                last = now
                self.applyHost(elapsedMs: Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
#endif
