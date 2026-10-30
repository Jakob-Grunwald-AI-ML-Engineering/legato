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
    /// How long a finished keyboard run waits for the keyboard to confirm its text landed (the keyboard
    /// types it out over a moment, so it counts from the end of that).
    static let appliedTimeout: TimeInterval = 2

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-link")

    let link: HostLink
    /// The run's text for the app's own screen (the hop view), after every update.
    var onTranscript: (@MainActor (_ committed: String, _ volatile: String) -> Void)?
    /// A run began (true) or ended (false).
    var onRunStarted: (@MainActor (String) -> Void)?
    var onRunActivity: (@MainActor (Bool) -> Void)?
    /// The mic lease between runs: when it ends, or nil when it is not held.
    var onLease: (@MainActor (Date?) -> Void)?
    /// Optional operational evidence: no transcript leaves this callback.
    var onDelivery: (@MainActor (_ runID: String, _ confirmed: Bool) -> Void)?
    /// The keyboard's choices, drained from the App Group (on its note and when listening starts).
    var onChoices: (@MainActor ([ChoiceRecord]) -> Void)?
    /// How a run that starts now delivers its cleaned text (nil with cleanup off); asked once per run.
    var deliveryForRun: @MainActor () -> HostDelivery? = { nil }

    /// The current run's delivery, fixed when it started (a settings change mid-run applies to the next).
    private var runDelivery: HostDelivery?

    private var observers: [DarwinObserver] = []

    /// nil when the App Group is unavailable (misconfigured signing): the keyboard link is then off.
    init?() {
        guard let backing = UserDefaultsLinkStore() else {
            Self.log.error("App Group defaults unavailable; keyboard link is off")
            return nil
        }
        link = HostLink(store: LinkStore(backing))
        #if DEBUG || LEGATO_INTERNAL
        link.onPublish = { state in
            #if DEBUG
            E2E.log("""
                link.host phase=\(state.phase.rawValue) final=\(state.isFinal ? 1 : 0) target=\(state.target.rawValue) \
                committed=\(E2E.quote(state.committed)) volatile=\(E2E.quote(state.volatile)) \
                lease=\(state.leaseUntil == nil ? 0 : 1) accepts=\(state.acceptsRemoteStart ? 1 : 0) meeting=\(state.meetingRecording == true ? 1 : 0) seq=\(state.seq) preparing=\(state.preparingRequestID == nil ? 0 : 1)
                """)
            #endif
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
            DarwinObserver(name: LinkChannel.Note.refine) {
                Task { @MainActor in await link.processRefine() }
            },
            DarwinObserver(name: LinkChannel.Note.choice) { [weak self] in
                Task { @MainActor in self?.drainChoices() }
            },
        ]
        drainChoices() // choices made while the app was away
    }

    /// Reads the queued choices now (the app came to the foreground; the Darwin note can be missed in the background).
    func drainChoices() {
        let records = link.drainChoices()
        if !records.isEmpty { onChoices?(records) }
    }

    var keyboardIsVisible: Bool { link.keyboardIsVisible() }

    /// How long an insert waits for the keyboard to confirm its text landed (it types the whole text out).
    static let insertTimeout: TimeInterval = 4

    /// The Live Activity's Insert button: publishes `text` for the keyboard on screen (flagged as asked for)
    /// and waits for it to confirm. False when no Legato keyboard is visible, a run is going on, or the
    /// keyboard did not confirm in time.
    func insert(_ text: String) async -> Bool {
        let id = UUID().uuidString
        guard keyboardIsVisible else {
            #if DEBUG
            WakeProbeLog.log("skip", "reason=keyboardNotVisible run=\(id.prefix(8))")
            #endif
            return false
        }
        guard link.publishInsert(runID: id, text: text) else {
            #if DEBUG
            WakeProbeLog.log("skip", "reason=runInProgress run=\(id.prefix(8))")
            #endif
            return false
        }
        #if DEBUG
        WakeProbeLog.log("post", "run=\(id.prefix(8)) seq=\(link.state.seq) chars=\(text.count)")
        let started = Date()
        #endif
        let confirmed = await link.awaitFinalApplied(runID: id, timeout: Self.insertTimeout)
        #if DEBUG
        let waited = Int((Date().timeIntervalSince(started) * 1000).rounded())
        WakeProbeLog.log("confirm", "run=\(id.prefix(8)) confirmed=\(confirmed ? 1 : 0) waitedMs=\(waited)")
        #endif
        return confirmed
    }

    // MARK: TranscriptSink

    func runStarted(_ run: DictationRun) {
        onRunStarted?(run.id.uuidString)
        // Cleanup delivery is about the keyboard's field: a run for the app's own screen or the activity's
        // result has none (the cleaned text is its text), so the keyboard shows no hold text for it.
        runDelivery = run.target == .keyboard ? deliveryForRun() : nil
        link.runStarted(id: run.id.uuidString, target: run.target == .keyboard ? .keyboard : .app, delivery: runDelivery)
        onRunActivity?(true)
    }

    func runFinishing(_ run: DictationRun) {
        link.runFinishing()
    }

    func update(committed: String, volatile: String) {
        link.update(committed: committed, volatile: volatile)
        onTranscript?(committed, volatile)
    }

    /// Live cleanup's newest version of the run's text: the keyboard replaces what its field shows for the run
    /// while the field still ends with it.
    func revised(_ revision: TranscriptRevision) {
        link.revise(HostRevision(n: revision.n, start: revision.start, raw: revision.raw, text: revision.text))
    }

    /// The tentative text the keyboard's field showed when it was cleared at `boundary`: it went with the message.
    func sentTentative(runID: String, boundary: Int) -> String {
        link.sentTentative(runID: runID, boundary: boundary)
    }

    func liveTraced(_ event: LiveTraceEvent) {
    }

    /// With cleanup, `text` is the cleaned text: the keyboard swaps it in (`.replace`), keeps the streamed
    /// text (`.clipboard`: never confirmed, so the cleaned text goes to the clipboard) or inserts it (`.hold`).
    func runEnded(_ run: DictationRun, committed: String, text: String?) async -> Bool {
        let raw = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = text.flatMap { $0 != raw ? $0 : nil }
        link.runEnded(committed: committed, finalText: finalText)
        onTranscript?(text ?? committed, "")
        onRunActivity?(false)
        // Only a run streamed into a visible keyboard has anything to confirm.
        guard run.target == .keyboard, text != nil, link.keyboardIsVisible() else {
            onDelivery?(run.id.uuidString, false)
            return false
        }
        let applied = await link.awaitFinalApplied(runID: run.id.uuidString, timeout: Self.appliedTimeout)
        onDelivery?(run.id.uuidString, applied)
        if runDelivery == .clipboard, finalText != nil { return false }
        return applied
    }

    func leaseChanged(until: Date?) {
        link.leaseChanged(until: until)
        onLease?(until)
    }
}
