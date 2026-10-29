import Foundation
import LegatoAppServices
import LegatoCore
import LegatoFieldEdit
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
    /// Whether the experimental edit queue is on; read once per run, like `deliveryForRun`.
    var fieldEditsForRun: @MainActor () -> Bool = { false }

    // The experimental edit queue's side of a run (the setting on, a keyboard run, Live or Replace).
    /// The session's own cleanup; switched off while the cleanup agent cleans the run (Live).
    var agentGate: AgentGatedPostProcessor?
    /// Makes the run's agent on the warm rolling session (nil: none); called in the background, never awaited by the run.
    var makeAgent: @MainActor (_ runID: String) -> (@Sendable () async -> CleanupAgent?)? = { _ in nil }
    /// How long a stop waits for an agent that is still warming (the run's cleanup time limit).
    var agentWait: @MainActor () -> Duration = { .seconds(2) }
    /// Today's stateless final cleanup pass, for a Live run whose agent was absent at its stop.
    var statelessFinalPass: @MainActor (String) async -> String? = { _ in nil }
    /// Puts a fallback text on the clipboard; false when the clipboard did not change.
    var copyFallback: @MainActor (String) -> Bool = { _ in false }
    /// The session saved the engine's text; the history then holds what the field got (`AgentRunHistory`).
    var correctHistory: @MainActor (_ raw: String, _ cleaned: String) async -> Void = { _, _ in }
    /// Diagnostics of the linked run (DEBUG e2e); no user text.
    var linkTrace: (@MainActor (String) -> Void)?

    private var feedLink: FieldFeedLink?
    /// The current run's side of the edit queue; nil with the setting off (today's paths).
    private var linked: LinkedCleanupRun?

    /// The current run's delivery, fixed when it started (a settings change mid-run applies to the next).
    private var runDelivery: HostDelivery?
    /// The current run's edit-queue flag, fixed when it started.
    private var runFieldEdits = false

    private var observers: [DarwinObserver] = []
    #if LEGATO_INTERNAL
    private let trace = LiveTrace()
    #endif

    /// nil when the App Group is unavailable (misconfigured signing): the keyboard link is then off.
    init?() {
        guard let backing = UserDefaultsLinkStore() else {
            Self.log.error("App Group defaults unavailable; keyboard link is off")
            return nil
        }
        let store = LinkStore(backing)
        link = HostLink(store: store)
        feedLink = FieldFeedLink(store: store)
        #if DEBUG || LEGATO_INTERNAL
        #if LEGATO_INTERNAL
        var wasPreparing = false
        #endif
        link.onPublish = { state in
            #if DEBUG
            E2E.log("""
                link.host phase=\(state.phase.rawValue) final=\(state.isFinal ? 1 : 0) target=\(state.target.rawValue) \
                committed=\(E2E.quote(state.committed)) volatile=\(E2E.quote(state.volatile)) \
                lease=\(state.leaseUntil == nil ? 0 : 1) accepts=\(state.acceptsRemoteStart ? 1 : 0) meeting=\(state.meetingRecording == true ? 1 : 0) seq=\(state.seq) preparing=\(state.preparingRequestID == nil ? 0 : 1)
                """)
            #endif
            #if LEGATO_INTERNAL
            let preparing = state.preparingRequestID != nil
            if preparing != wasPreparing {
                AudioDiagnostics.log("keyboard.preparation", ["pending": preparing, "phase": state.phase.rawValue])
                wasPreparing = preparing
            }
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
            DarwinObserver(name: LinkChannel.Note.feed) { [weak self] in
                Task { @MainActor in self?.linked?.feedChanged() }
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
        runFieldEdits = run.target == .keyboard && fieldEditsForRun()
        startLinkedRun(run.id.uuidString)
        link.runStarted(
            id: run.id.uuidString, target: run.target == .keyboard ? .keyboard : .app, delivery: runDelivery,
            fieldEdits: runFieldEdits ? true : nil)
        onRunActivity?(true)
        #if LEGATO_INTERNAL
        trace.runStarted(run, delivery: runDelivery)
        #endif
    }

    func runFinishing(_ run: DictationRun) {
        link.runFinishing()
    }

    func update(committed: String, volatile: String) {
        link.update(committed: committed, volatile: volatile)
        linked?.heard(committed: committed, volatile: volatile)
        onTranscript?(committed, volatile)
        #if LEGATO_INTERNAL
        trace.update(committed: committed)
        #endif
    }

    /// Live cleanup's newest version of the run's text: the keyboard replaces what its field shows for the run
    /// while the field still ends with it.
    func revised(_ revision: TranscriptRevision) {
        link.revise(HostRevision(n: revision.n, start: revision.start, raw: revision.raw, text: revision.text))
        #if LEGATO_INTERNAL
        trace.revised(revision)
        #endif
    }

    /// The tentative text the keyboard's field showed when it was cleared at `boundary`: it went with the message.
    func sentTentative(runID: String, boundary: Int) -> String {
        link.sentTentative(runID: runID, boundary: boundary)
    }

    func liveTraced(_ event: LiveTraceEvent) {
        #if LEGATO_INTERNAL
        trace.traced(event)
        #endif
    }

    /// With cleanup, `text` is the cleaned text: the keyboard swaps it in (`.replace`), keeps the streamed
    /// text (`.clipboard`: never confirmed, so the cleaned text goes to the clipboard) or inserts it (`.hold`).
    func runEnded(_ run: DictationRun, committed: String, text: String?) async -> Bool {
        let linked = self.linked
        self.linked = nil
        defer { agentGate?.agentRuns = false }  // the session's stop (its final pass) is behind us
        let raw = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = text.flatMap { $0 != raw ? $0 : nil }
        link.runEnded(committed: committed, finalText: finalText)
        onTranscript?(text ?? committed, "")
        onRunActivity?(false)
        // Only a run streamed into a visible keyboard has anything to confirm.
        guard run.target == .keyboard, text != nil, link.keyboardIsVisible() else {
            linked?.cancel()
            #if LEGATO_INTERNAL
            trace.runEnded(applied: nil, confirmed: false)
            #endif
            onDelivery?(run.id.uuidString, false)
            return false
        }
        var applied = await link.awaitFinalApplied(runID: run.id.uuidString, timeout: Self.appliedTimeout)
        if let linked, let text {
            applied = await finishLinked(linked, committed: committed, text: text, finalText: finalText, applied: applied)
        }
        onDelivery?(run.id.uuidString, applied)
        #if LEGATO_INTERNAL
        trace.runEnded(applied: link.appliedCursor(), confirmed: applied)
        #endif
        if runDelivery == .clipboard, finalText != nil { return false }
        return applied
    }

    // MARK: Edit queue (the setting on)

    /// Starts the run's side of the edit queue: for a keyboard run with the setting on, in Live (the cleanup agent
    /// on the warm rolling session, so the session's own cleanup stays out) or Replace (the final pass as patches).
    private func startLinkedRun(_ runID: String) {
        linked?.cancel()
        linked = nil
        agentGate?.agentRuns = false
        guard runFieldEdits, runDelivery == .live || runDelivery == .replace, let feedLink else { return }
        feedLink.beginRun(runID)
        let reader = FeedReader(link: feedLink, runID: runID)
        let transport = LinkedCleanupRun.Transport(
            read: { reader.read() }, send: { [weak self] transactions in
                let dropped = feedLink.sendEdits(transactions)
                if dropped > 0 { self?.linkTrace?("link.edits dropped=\(dropped)") }
            })
        let agent = runDelivery == .live ? makeAgent(runID) : nil
        let run = LinkedCleanupRun(owner: runID, agent: agent, transport: transport, agentWait: agentWait())
        run.trace = linkTrace
        linked = run
        // The agent cleans a Live run; the session runs no rolling passes and no final pass of its own.
        agentGate?.agentRuns = run.hasAgent
        linkTrace?("link.run delivery=\(runDelivery?.rawValue ?? "-") agent=\(run.hasAgent ? 1 : 0)")
    }

    /// The stop of a linked run, once the keyboard confirmed (or not) the streamed text. Returns whether the final
    /// text is in the field, or (Live) whether the cleaned text is on the clipboard instead (then the session's raw
    /// text must not replace it there). See `LinkedCleanupRun`.
    private func finishLinked(
        _ linked: LinkedCleanupRun, committed: String, text: String, finalText: String?, applied: Bool
    ) async -> Bool {
        if runDelivery == .replace {
            guard let finalText else { return applied }
            // The stateless pass's text as patches; not landed: today's clipboard fallback (the cleaned text).
            return await linked.deliver(raw: committed, cleaned: finalText) == .applied && applied
        }
        let outcome = await linked.finish()
        var cleaned: String?
        var fallback: String?
        if outcome.agentAbsent {
            if let pass = await statelessFinalPass(text) {
                switch await linked.deliver(raw: committed, cleaned: pass) {
                case .applied: cleaned = pass
                case .unchanged: break
                default: fallback = pass
                }
            }
        } else if outcome.unapplied.isEmpty {
            cleaned = linked.mirror.runText
        } else {
            fallback = linked.fallbackText(unapplied: outcome.unapplied)
        }
        var landed = applied
        if fallback != nil || !applied, let copy = fallback ?? cleaned, copy != text {
            // The field changed under the agent's edits (or never confirmed): the cleaned text goes to the clipboard.
            landed = copyFallback(copy)
            linkTrace?("link.fallback copied=\(landed ? 1 : 0)")
            cleaned = copy
        }
        if let cleaned, !linked.mirror.wasCleared { await correctHistory(text, cleaned) }
        return landed
    }

    func leaseChanged(until: Date?) {
        link.leaseChanged(until: until)
        onLease?(until)
    }
}

/// The app's reading position in the run's `link.feed`: the first read takes the run from its start.
@MainActor
private final class FeedReader {
    private let link: FieldFeedLink
    private let runID: String
    private var cursor: FeedCursor?

    init(link: FieldFeedLink, runID: String) {
        self.link = link
        self.runID = runID
    }

    func read() -> [FeedBatch] {
        let read = cursor == nil ? link.readFeedFromStart(forRun: runID) : link.readFeed(after: cursor, forRun: runID)
        guard let read else { return [] }
        cursor = read.cursor
        return read.batches
    }
}
