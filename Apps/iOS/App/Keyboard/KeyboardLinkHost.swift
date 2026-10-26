import Foundation
import LegatoCore
import LegatoKeyboardCore
import os

/// The app's side of the keyboard link: the coordinator's transcript sink, publishing each run to the
/// keyboard through the App Group (`HostLink`), and the listener for the keyboard's Darwin notes.
/// The logic lives in LegatoKeyboardCore; this type only adapts it to the coordinator's port and
/// the system.
@MainActor
final class KeyboardLinkHost: TranscriptSink {
    /// How long a finished keyboard run waits for the keyboard to confirm its text landed.
    static let appliedTimeout: TimeInterval = 1

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-link")

    let link: HostLink
    /// The run's text for the app's own screen (the hop view), after every update.
    var onTranscript: (@MainActor (_ committed: String, _ volatile: String) -> Void)?
    /// A run began (true) or ended (false).
    var onRunActivity: (@MainActor (Bool) -> Void)?
    /// The mic lease between runs: when it ends, or nil when it is not held.
    var onLease: (@MainActor (Date?) -> Void)?

    private var observers: [DarwinObserver] = []

    /// nil when the App Group is unavailable (misconfigured signing): the keyboard link is then off.
    init?() {
        guard let backing = UserDefaultsLinkStore() else {
            Self.log.error("App Group defaults unavailable; keyboard link is off")
            return nil
        }
        link = HostLink(store: LinkStore(backing))
        #if DEBUG
        link.onPublish = { state in
            E2E.log("""
                link.host phase=\(state.phase.rawValue) final=\(state.isFinal ? 1 : 0) target=\(state.target.rawValue) \
                committed=\(E2E.quote(state.committed)) volatile=\(E2E.quote(state.volatile)) \
                lease=\(state.leaseUntil == nil ? 0 : 1) accepts=\(state.acceptsRemoteStart ? 1 : 0) seq=\(state.seq)
                """)
        }
        #endif
    }

    /// Starts listening for the keyboard's notes. The request inbox is read only on a note, never at
    /// launch: a leftover request must not start a dictation.
    func startListening() {
        let link = self.link
        observers = [
            DarwinObserver(name: LinkChannel.Note.request) {
                Task { @MainActor in await link.processInbox() }
            },
            DarwinObserver(name: LinkChannel.Note.applied) {
                Task { @MainActor in link.appliedDidChange() }
            },
        ]
    }

    var keyboardIsVisible: Bool { link.keyboardIsVisible() }

    // MARK: TranscriptSink

    func runStarted(_ run: DictationRun) {
        link.runStarted(id: run.id.uuidString, target: run.target == .keyboard ? .keyboard : .app)
        onRunActivity?(true)
    }

    func update(committed: String, volatile: String) {
        link.update(committed: committed, volatile: volatile)
        onTranscript?(committed, volatile)
    }

    func runEnded(_ run: DictationRun, committed: String, text: String?) async -> Bool {
        link.runEnded(committed: committed)
        onTranscript?(committed, "")
        onRunActivity?(false)
        // Only a run streamed into a visible keyboard has anything to confirm.
        guard run.target == .keyboard, text != nil, link.keyboardIsVisible() else { return false }
        return await link.awaitFinalApplied(runID: run.id.uuidString, timeout: Self.appliedTimeout)
    }

    func leaseChanged(until: Date?) {
        link.leaseChanged(until: until)
        onLease?(until)
    }
}
