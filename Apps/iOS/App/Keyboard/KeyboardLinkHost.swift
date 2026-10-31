import Foundation
import LegatoCore
import LegatoAppServices
import LegatoAgent
import LegatoComposerDoc
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
    private var composerTask: Task<Void, Never>?
    private var composerHistory = ComposerLinkHistory()
    private var composerPublisher = ComposerPublicationPublisher()
    private var composerRevision = -1
    private var preparingComposerInsert = false
    private var composerInsertTask: Task<Void, Never>?
    private var composerInsertionNotice: String?
    private var insertedComposerIntentID: String?
    private var composerSessionID: String?
    private var composerChannel: ComposerLink?
    /// Open while the keyboard is on screen; its surface decides where a mic tap routes audio.
    private(set) var keyboardSession: KeyboardSession?
    private var dictationPublished: (sessionID: String, lines: [DictationDelivery])?
    func attach(_ composer: ComposerSession, keyboardSession: KeyboardSession? = nil, dictation: DictationPipeline? = nil) {
        self.keyboardSession = keyboardSession
        dictation?.contextBefore = { [weak self] in self?.link.keyboardPresence()?.contextBefore ?? "" }
        guard let backing = UserDefaultsLinkStore() else { return }
        let channel = ComposerLink(store: LinkStore(backing)); composerChannel = channel
        let dictationChannel = DictationLink(store: LinkStore(backing))
        composer.hostInsertionTarget = { [weak self] in self?.link.keyboardDocumentID() }
        composer.hostInsertionUnavailableReason = { "No visible Legato keyboard text field is bound." }
        composer.hostInsertDraft = { [weak self, weak composer] documentID in
            guard let self, let composer else { return .init(succeeded: false, message: "Composer closed. Draft kept.") }
            return await self.insertComposerDraft(composer, expectedDocumentID: documentID, origin: .instruction)
        }
        composer.onChange = { [weak self, weak composer] in
            guard let self, let composer else { return }
            if composer.sessionID != self.composerSessionID {
                self.composerInsertionNotice = nil
                self.composerSessionID = composer.sessionID; self.composerHistory = ComposerLinkHistory(); self.composerRevision = -1
            }
            if composer.snapshot.revision != self.composerRevision {
                self.composerHistory.record(composer.snapshot, hunks: composer.hunks)
                self.composerRevision = composer.snapshot.revision
            }
        }
        composerTask = Task { [weak self, weak composer] in
            while !Task.isCancelled {
                guard let self, let composer else { return }
                // Presence drives the keyboard session: appear opens and pre-warms, disappear closes.
                if let session = self.keyboardSession {
                    let presence = self.link.keyboardPresence()
                    session.update(visible: presence != nil, surface: presence?.surface == .typing ? .dictation : .agent)
                }
                if let dictation {
                    if let ack = dictationChannel.acknowledged() { dictation.acknowledge(sessionID: ack.sessionID, upTo: ack.upTo) }
                    // Cleaned lines wait here until the keyboard acknowledges having typed them.
                    if dictationPublished?.sessionID != dictation.sessionID || dictationPublished?.lines != dictation.outbox {
                        dictationPublished = (dictation.sessionID, dictation.outbox)
                        dictationChannel.publish(.init(sessionID: dictation.sessionID, lines: dictation.outbox.map {
                            .init(lineID: $0.lineID, seq: $0.sequence, raw: $0.raw, text: $0.text, status: $0.cleaned ? .cleaned : .raw)
                        }))
                        DarwinObserver.post(LinkChannel.Note.dictation)
                    }
                }
                for intent in channel.drainIntents() {
                    switch intent.action {
                    case "insert":
                        guard self.composerInsertTask == nil else { continue }
                        self.composerInsertTask = Task { [weak self, weak composer] in
                            guard let self, let composer else { return }
                            defer { self.composerInsertTask = nil; self.insertedComposerIntentID = intent.id }
                            guard intent.sessionID == composer.sessionID else { return }
                            let result = await self.insertComposerDraft(composer, expectedDocumentID: self.link.keyboardDocumentID(), origin: .keyboardButton)
                            self.composerInsertionNotice = result.succeeded ? nil : result.message
                        }
                    case "cancel": await composer.cancel(); await self.keyboardSession?.rewarm()
                    case "undo": await composer.undo()
                    case "stop":
                        if let session = self.keyboardSession, session.isOpen { await session.closeGate() } else { await composer.stop() }
                    case "mute":
                        let muted = intent.text.flatMap(Bool.init) ?? !composer.isMuted
                        await composer.setMuted(muted)
                    case "mode": if let text = intent.text, let mode = ComposerMode(rawValue: text) { await composer.setMode(mode) }
                    case "tap":
                        if let line = intent.lineID, let word = intent.wordID {
                            await composer.select(lineID: line, wordID: word, endLineID: intent.endLineID,
                                                  endWordID: intent.endWordID, timestamp: intent.timestamp)
                        }
                    case "send-correction": await composer.sendCorrection()
                    case "discard-instruction": await composer.discardInstruction(timestamp: intent.timestamp)
                    case "deselect": await composer.clearSelection(timestamp: intent.timestamp)
                    case "pick": if let line = intent.lineID, let word = intent.wordID, let text = intent.text { await composer.pick(lineID: line, wordID: word, text: text) }
                    default: break
                    }
                }
                if composer.sessionID != self.composerSessionID {
                    self.composerInsertionNotice = nil
                    self.composerSessionID = composer.sessionID; self.composerHistory = ComposerLinkHistory(); self.composerRevision = -1
                }
                if composer.snapshot.revision != self.composerRevision {
                    self.composerHistory.record(composer.snapshot, hunks: composer.hunks); self.composerRevision = composer.snapshot.revision
                }
                var value = self.composerHistory.publication(acknowledged: channel.acknowledged)
                value.insertedIntentID = self.insertedComposerIntentID
                value.dictationRevision = composer.dictationRevision
                value.dictationCommit = composer.dictationCommit
                value.successfulInsertionID = composer.successfulInsertionID
                value.sessionID = composer.sessionID; value.tail = composer.tail; value.mode = composer.mode.rawValue
                value.correctionDraft = composer.correctionDraft
                value.correctionSubmitting = composer.correctionSubmitting
                value.correctionCountdownStart = composer.correctionCountdownStart
                value.correctionCountdownDeadline = composer.correctionCountdownDeadline
                value.instructionDraft = composer.instructionPreview; value.instructionStatus = composer.instructionStatus
                value.audioRoute = (self.keyboardSession?.isOpen == true ? self.keyboardSession?.route : nil)?.rawValue ?? composer.route.rawValue
                value.dictationTail = self.keyboardSession?.dictationTail
                value.muted = composer.isMuted; value.status = composer.status; value.error = composer.error ?? self.composerInsertionNotice; value.busy = composer.busy; value.pendingLineIDs = composer.pendingLineIDs
                if self.composerPublisher.publish(value, through: channel) {
                    DarwinObserver.post(LinkChannel.Note.composer)
                }
                self.link.leaseChanged(until: composer.isArmed || composer.isListening ? Date().addingTimeInterval(60) : nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

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

    /// Both the visible Insert key and explicit Instructions use this same guarded delivery.
    private func insertComposerDraft(_ composer: ComposerSession, expectedDocumentID: String?, origin: ComposerInsertOrigin) async -> ComposerHostActionResult {
        guard !preparingComposerInsert else { return .init(succeeded: false, message: "Insertion already in progress. Draft kept.") }
        preparingComposerInsert = true
        defer { preparingComposerInsert = false }
        let requestedSessionID = composer.sessionID
        await composer.traceInsertion("requested", origin: origin)
        do {
            let text = try await composer.prepareForInsertion()
            guard requestedSessionID == composer.sessionID else { return .init(succeeded: false, message: "Composition changed. Insertion discarded.") }
            guard expectedDocumentID == nil || link.keyboardDocumentID() == expectedDocumentID else {
                await composer.traceInsertion("undelivered", origin: origin, detail: ["reason": "target.changed"])
                return .init(succeeded: false, message: "The target text field changed. Draft kept.")
            }
            let sessionID = composer.sessionID, snapshot = composer.snapshot, tail = composer.tail
            guard !text.isEmpty else { return .init(succeeded: false, message: "The composer is empty.") }
            let delivered = await insert(text, documentID: expectedDocumentID)
            // The acknowledgement is the keyboard's `finalApplied`: UIKit proxy operations ran. It does not
            // independently prove the target app shows the text.
            await composer.traceInsertion(delivered ? "acknowledged" : "undelivered", origin: origin,
                detail: delivered ? ["ack": "keyboard.finalApplied"] : ["reason": "no.keyboard.ack"])
            if delivered, composer.sessionID == sessionID, composer.snapshot == snapshot, composer.tail == tail {
                // Within one keyboard appearance the draft and conversation continue after Insert.
                await composer.insert(retainingComposition: keyboardSession?.isOpen == true)
                return .init(succeeded: true, message: "Draft inserted into the bound text field.")
            }
            return .init(succeeded: delivered, message: delivered ? "Inserted. Draft changed during insertion; latest edits kept." : "Couldn't insert into the text field. Draft kept.")
        } catch {
            await composer.traceInsertion("undelivered", origin: origin, detail: ["reason": "prepare.failed"])
            return .init(succeeded: false, message: "Couldn't finish preparing the text. Draft kept. Try Insert again.")
        }
    }

    /// How long an insert waits for the keyboard to confirm its text landed (it types the whole text out).
    static let insertTimeout: TimeInterval = 4

    /// The Live Activity's Insert button: publishes `text` for the keyboard on screen (flagged as asked for)
    /// and waits for it to confirm. False when no Legato keyboard is visible, a run is going on, or the
    /// keyboard did not confirm in time.
    func insert(_ text: String, documentID: String? = nil) async -> Bool {
        let id = UUID().uuidString
        guard keyboardIsVisible else {
            #if DEBUG
            WakeProbeLog.log("skip", "reason=keyboardNotVisible run=\(id.prefix(8))")
            #endif
            return false
        }
        guard link.publishInsert(runID: id, text: text, documentID: documentID) else {
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
