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
final class KeyboardLinkHost {
    /// How long a finished keyboard run waits for the keyboard to confirm its text landed (the keyboard
    /// types it out over a moment, so it counts from the end of that).
    static let appliedTimeout: TimeInterval = 2

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-link")

    let link: HostLink
    var onChoices: (@MainActor ([ChoiceRecord]) -> Void)?
    private var observers: [DarwinObserver] = []
    private var statusTask: Task<Void, Never>?
    private var publishedStatus: DictationStatus?
    /// Open while the keyboard is on screen; its surface decides where a mic tap routes audio.
    private(set) var keyboardSession: KeyboardSession?
    /// Live dictation (the send mode `live`): the run's snapshot goes to the link at most every `minPublishInterval`
    /// (the latest wins), and the keyboard's ack is only read for diagnostics.
    private var liveLatest: LiveDictationSnapshot?
    private var liveWritten: LiveDictationSnapshot?
    private var liveLastWrite = ContinuousClock.now - .seconds(1)
    private var liveWriteTask: Task<Void, Never>?
    private var liveVersionTimes: [Int: ContinuousClock.Instant] = [:]
    private var liveAckSeen: LiveDictationAck?
    /// Instruction mode's end of the link (reads, scoped edits, the strip); the session holds it weakly.
    private var instructionChannel: InstructionFieldChannel?
    func attach(_ microphone: MicrophoneHost, keyboardSession: KeyboardSession, dictation: DictationPipeline) {
        self.keyboardSession = keyboardSession
        dictation.contextBefore = { [weak self] in self?.link.keyboardPresence()?.contextBefore ?? "" }
        guard let backing = UserDefaultsLinkStore() else { return }
        let channel = DictationStatusLink(store: LinkStore(backing))
        let instructionChannel = InstructionFieldChannel(store: LinkStore(backing))
        self.instructionChannel = instructionChannel
        keyboardSession.instruction.field = instructionChannel
        dictation.attachCleanupField(instructionChannel, duringPauses: false)
        let liveChannel = LiveDictationLink(store: LinkStore(backing))
        let publishDictation: @MainActor () -> Void = { [weak self, weak dictation] in
            guard let self, let dictation, dictation.mode != .live else { return }
            self.publishLive(dictation.deliverySnapshot, through: liveChannel, diagnostics: dictation.diagnostics)
        }
        dictation.onChange = publishDictation

        dictation.onLiveChange = { [weak self, weak dictation] snapshot in
            self?.publishLive(snapshot, through: liveChannel, diagnostics: dictation?.diagnostics)
        }
        statusTask = Task { [weak self, weak microphone] in
            while !Task.isCancelled {
                guard let self, let microphone else { return }
                // Presence drives the keyboard session: appear opens and pre-warms, disappear closes.
                if let session = self.keyboardSession {
                    let presence = self.link.keyboardPresence()
                    session.update(visible: presence != nil, surface: .dictation)
                    // A keyboard that went away says nothing about the toggle: closing the session drops the instruction.
                    if let presence { session.magicReported(presence.magic ?? .off) }
                    for intent in instructionChannel.drainIntents() { session.handle(intent) }
                }
                do {
                    let liveAck = liveChannel.acknowledged()
                    if let liveAck { dictation.acknowledgeDelivery(liveAck) }
                    self.logLiveAck(liveAck, diagnostics: dictation.diagnostics)
                    publishDictation()
                }
                for intent in channel.drainIntents() {
                    switch intent.action {
                    case .stop: await self.keyboardSession?.closeGate()
                    case .retry: Task { await dictation.retry() }
                    case .insertAsIs: Task { await dictation.insertRaw() }
                    }
                }
                var value = DictationStatus()
                value.fieldCleanupOutcome = dictation.fieldCleanupOutcome
                value.audioRoute = self.keyboardSession?.route ?? .idle
                value.dictationTail = self.keyboardSession?.dictationTail
                value.dictationTake = dictation.takeDisplay
                value.dictationTakePhase = dictation.takePhase
                value.dictationCountdownStart = dictation.countdownStart
                value.dictationCountdownDeadline = dictation.countdownDeadline
                value.voiceIsolationStatus = self.keyboardSession?.dictationVoiceIsolationStatus
                value.dictationNotice = self.keyboardSession?.dictationNotice
                value.dictationNoticeID = self.keyboardSession?.dictationNoticeID
                value.error = microphone.error
                if value != self.publishedStatus {
                    channel.publish(value)
                    self.publishedStatus = value
                    DarwinObserver.post(LinkChannel.Note.dictationStatus)
                }
                self.link.listeningChanged(self.keyboardSession?.route == .dictation)
                self.link.leaseChanged(until: microphone.isArmed ? Date().addingTimeInterval(60) : nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func publishLive(_ snapshot: LiveDictationSnapshot?, through channel: LiveDictationLink,
                             diagnostics: (@MainActor (String, [String: Any]) -> Void)?) {
        liveLatest = snapshot
        guard let snapshot else {
            liveWriteTask?.cancel(); liveWriteTask = nil
            liveWritten = nil; liveVersionTimes = [:]
            channel.clear()
            DarwinObserver.post(LinkChannel.Note.dictationLive)
            return
        }
        let wait = LinkChannel.minPublishInterval - Double(liveLastWrite.duration(to: .now).components.attoseconds) / 1e18
            - Double(liveLastWrite.duration(to: .now).components.seconds)
        if wait <= 0 { writeLive(channel, diagnostics: diagnostics); return }
        guard liveWriteTask == nil else { return }
        liveWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.liveWriteTask = nil
            self.writeLive(channel, diagnostics: diagnostics)
        }
    }

    private func writeLive(_ channel: LiveDictationLink, diagnostics: (@MainActor (String, [String: Any]) -> Void)?) {
        guard let snapshot = liveLatest, snapshot != liveWritten else { return }
        liveWritten = snapshot; liveLastWrite = .now
        liveVersionTimes[snapshot.version] = .now
        if liveVersionTimes.count > 64 { liveVersionTimes = liveVersionTimes.filter { $0.key > snapshot.version - 32 } }
        channel.publish(snapshot)
        DarwinObserver.post(LinkChannel.Note.dictationLive)
        diagnostics?("live2.publish", ["run": String(snapshot.runID.prefix(8)), "v": snapshot.version, "segments": snapshot.segments.count,
                                       "chars": snapshot.segments.reduce(0) { $0 + $1.text.count }, "complete": snapshot.complete])
    }

    /// The keyboard's counters (what it applied, flipped, froze), logged when they change; no text.
    private func logLiveAck(_ ack: LiveDictationAck?, diagnostics: (@MainActor (String, [String: Any]) -> Void)?) {
        guard let ack, ack != liveAckSeen else { return }
        liveAckSeen = ack
        var fields: [String: Any] = ["run": String(ack.runID.prefix(8)), "complete": ack.complete, "applies": ack.stats.applies,
                                     "rewrites": ack.stats.rewrites, "inserted": ack.stats.insertedChars, "deleted": ack.stats.deletedChars,
                                     "freezes": ack.stats.freezes, "drifts": ack.stats.drifts, "waits": ack.stats.waits,
                                     "confirmTimeouts": ack.stats.confirmTimeouts, "coalesced": ack.stats.coalesced]
        if let cause = ack.stats.lastFreeze { fields["lastFreeze"] = cause }
        if let drift = ack.stats.lastDrift { fields["drift"] = drift }
        if let start = ack.stats.lastStart { fields["start"] = start }
        if let version = ack.version {
            fields["v"] = version
            if let at = liveVersionTimes[version] {
                let parts = at.duration(to: .now).components
                fields["ms"] = Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
            }
        }
        diagnostics?("live2.ack", fields)
    }

    /// nil when the App Group is unavailable (misconfigured signing): the keyboard link is then off.
    init?() {
        guard let backing = UserDefaultsLinkStore() else {
            Self.log.error("App Group defaults unavailable; keyboard link is off")
            return nil
        }
        link = HostLink(store: LinkStore(backing))

    }

    /// Starts listening for the keyboard's notes. The request inbox is read only on a note, never at
    /// launch: a leftover request must not start a dictation.
    func startListening() {
        let link = self.link
        observers = [
            DarwinObserver(name: LinkChannel.Note.request) {
                Task { @MainActor in await link.processInbox() }
            },
            DarwinObserver(name: LinkChannel.Note.choice) { [weak self] in
                Task { @MainActor in self?.drainChoices() }
            },
            // The magic key and the strip's taps act at once, not at the next pass of the loop.
            DarwinObserver(name: LinkChannel.Note.presence) { [weak self] in
                Task { @MainActor in self?.instructionNote() }
            },
            DarwinObserver(name: LinkChannel.Note.instructionIntent) { [weak self] in
                Task { @MainActor in self?.instructionNote() }
            },
        ]
        drainChoices() // choices made while the app was away
    }

    private func instructionNote() {
        guard let session = keyboardSession, session.isOpen else { return }
        if let presence = link.keyboardPresence() { session.magicReported(presence.magic ?? .off) }
        for intent in instructionChannel?.drainIntents() ?? [] { session.handle(intent) }
    }

    /// Reads the queued choices now (the app came to the foreground; the Darwin note can be missed in the background).
    func drainChoices() {
        let records = link.drainChoices()
        if !records.isEmpty { onChoices?(records) }
    }

    var keyboardIsVisible: Bool { link.keyboardIsVisible() }

}
