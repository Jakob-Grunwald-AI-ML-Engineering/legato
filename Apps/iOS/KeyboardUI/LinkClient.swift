import Foundation
import LegatoKeyboardCore

/// The keyboard's end of the link: reads what the app publishes (`link.host`, `link.ack`) and writes
/// what the keyboard reports (`link.presence`, `link.request`, `link.applied`), each write followed by
/// its payload-free Darwin note. A thin adapter over `LegatoKeyboardCore`; no logic of its own.
@MainActor
final class LinkClient {
    private let store: LinkStore?
    private var observers: [DarwinObserver] = []

    /// `store` is nil when the App Group is unavailable (no Full Access, or misconfigured signing):
    /// every read is then empty and every write a no-op.
    init(store: LinkStore? = UserDefaultsLinkStore().map(LinkStore.init)) {
        self.store = store
    }

    /// Calls `handler` on the main actor for every `link.host` note.
    func observeHost(_ handler: @escaping @MainActor () -> Void) {
        observers.append(DarwinObserver(name: LinkChannel.Note.host) {
            Task { @MainActor in handler() }
        })
    }

    func readHost() -> HostState? { store?.read(HostState.self, forKey: LinkChannel.Key.host) }
    func readAck() -> KeyboardAck? { store?.read(KeyboardAck.self, forKey: LinkChannel.Key.ack) }
    func readApplied() -> AppliedCursor? { store?.read(AppliedCursor.self, forKey: LinkChannel.Key.applied) }

    func writeApplied(_ cursor: AppliedCursor) {
        store?.write(cursor, forKey: LinkChannel.Key.applied)
        DarwinObserver.post(LinkChannel.Note.applied)
    }

    /// `notify`: also post the note (on a change of visibility; the 1 s refreshes stay quiet).
    func writePresence(visible: Bool, notify: Bool) {
        store?.write(KeyboardPresence(visible: visible, at: Date()), forKey: LinkChannel.Key.presence)
        if notify { DarwinObserver.post(LinkChannel.Note.presence) }
    }

    func send(_ command: RequestCommand, id: String) {
        store?.write(KeyboardRequest(id: id, command: command, at: Date()), forKey: LinkChannel.Key.request)
        DarwinObserver.post(LinkChannel.Note.request)
    }

    /// The app's answer to request `id`, or nil when none arrives within `timeout`.
    func awaitAck(id: String, timeout: TimeInterval) async -> AckResult? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        repeat {
            if let ack = store?.read(KeyboardAck.self, forKey: LinkChannel.Key.ack), ack.id == id { return ack.result }
            try? await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return nil
    }
}
