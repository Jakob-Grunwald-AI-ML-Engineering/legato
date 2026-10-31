import Foundation
import LegatoKeyboardCore

/// The keyboard's end of the link: reads what the app publishes (`link.host`, `link.ack`) and writes
/// what the keyboard reports (`link.presence`, `link.request`, `link.applied`), each write followed by
/// its payload-free Darwin note. A thin adapter over `LegatoKeyboardCore`; no logic of its own.
@MainActor
final class LinkClient {
    private let store: LinkStore?
    private var observers: [DarwinObserver] = []
    #if DEBUG
    var hidesHost = false
    #endif

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

    /// Stops the `link.host` observation; the handlers never run again.
    func stopObserving() { observers.removeAll() }

    func readHost() -> HostState? {
        #if DEBUG
        if hidesHost { return nil }
        #endif
        return store?.read(HostState.self, forKey: LinkChannel.Key.host)
    }
    func readAck() -> KeyboardAck? { store?.read(KeyboardAck.self, forKey: LinkChannel.Key.ack) }
    func readApplied() -> AppliedCursor? { store?.read(AppliedCursor.self, forKey: LinkChannel.Key.applied) }

    /// `notify`: also post the note. The app waits only for `finalApplied`, so the typewriter's per-tick
    /// writes stay quiet until the last one.
    func writeApplied(_ cursor: AppliedCursor, notify: Bool = true) {
        store?.write(cursor, forKey: LinkChannel.Key.applied)
        if notify { DarwinObserver.post(LinkChannel.Note.applied) }
    }

    /// `notify`: also post the note (on a change of visibility; the 1 s refreshes stay quiet).
    func writePresence(visible: Bool, notify: Bool, documentID: String? = nil, surface: KeyboardSurface? = nil, contextBefore: String? = nil) {
        store?.write(KeyboardPresence(visible: visible, at: Date(), documentID: documentID, surface: surface, contextBefore: contextBefore), forKey: LinkChannel.Key.presence)
        if notify { DarwinObserver.post(LinkChannel.Note.presence) }
    }

    /// The cleaned dictation lines the app has not yet had acknowledged (`link.dictation`).
    func readDictation() -> DictationPublication? { store.map { DictationLink(store: $0).read() } ?? nil }
    func readDictationAck() -> DictationAck? { store.map { DictationLink(store: $0).acknowledged() } ?? nil }
    /// Every line up to `ack.upTo` is typed or dropped; the app stops sending it.
    func writeDictationAck(_ ack: DictationAck) {
        guard let store else { return }
        DictationLink(store: store).acknowledge(ack)
        DarwinObserver.post(LinkChannel.Note.dictationAck)
    }

    func send(_ command: RequestCommand, id: String) {
        store?.write(KeyboardRequest(id: id, command: command, at: Date()), forKey: LinkChannel.Key.request)
        DarwinObserver.post(LinkChannel.Note.request)
    }

    /// Asks the app for a refined version of `text` (`link.refine`); the app acks `id` on `link.ack`.
    func sendRefine(_ text: String, id: String) {
        store?.write(RefineRequest(id: id, text: text, at: Date()), forKey: LinkChannel.Key.refine)
        DarwinObserver.post(LinkChannel.Note.refine)
    }

    /// Reports a word-row choice for the app to learn from (`link.choice.<uuid>`); no-op without the App Group.
    func writeChoice(_ record: ChoiceRecord) {
        guard let store else { return }
        ChoiceWriter.write(record, to: store)
    }

    /// The app's reply to refine request `id`, or nil when none arrives within `timeout`. The reply leaves
    /// the App Group once read (it carries dictated text).
    func awaitRefined(id: String, timeout: TimeInterval) async -> RefineReply? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        repeat {
            if let reply = store?.read(RefineReply.self, forKey: LinkChannel.Key.refined), reply.id == id {
                store?.remove(forKey: LinkChannel.Key.refined)
                return reply
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return nil
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
