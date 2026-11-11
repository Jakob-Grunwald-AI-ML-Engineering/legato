import Foundation
import LegatoKeyboardCore
import LegatoComposerDoc
import Observation
import UIKit
import os

/// The keyboard's brain, shared by the extension and the DEBUG harness in the app: shows the link's
/// state, turns the host's dictation text into edits of the document, reports what landed (`link.applied`),
/// keeps the presence beat while visible and decides what the mic key does.
///
/// Every write to the field goes through one queue (`FieldQueue`): the user's keys, deletes, cursor pans and
/// word-row edits, live dictation, typed lines, the host's text, cleanup and Magic. It alone moves the cursor,
/// sends one op at a time and confirms each against the field's report. Only a cursor walk that reads the field
/// for an instruction moves the cursor besides it, while the queue is paused and has nothing in flight.
@MainActor @Observable
final class KeyboardController {
    @ObservationIgnored let document: any TextDocument
    @ObservationIgnored private let link: LinkClient
    @ObservationIgnored private let hasFullAccess: @MainActor () -> Bool

    /// Diagnostics hook (the DEBUG harness logs it). Messages carry no user text.
    @ObservationIgnored var trace: (@MainActor (String) -> Void)?
    /// Where the globe key sends its touches (the extension's `UIInputViewController`).
    @ObservationIgnored weak var inputModeTarget: UIInputViewController?
    /// The typing rules and the page the key grid shows.
    @ObservationIgnored private(set) var typing: TypingModel!

    /// The app's last published state.
    private(set) var host: HostState?
    /// Refreshed by the presence beat and before the mic key decides, so freshness checks have a clock.
    private(set) var now = Date()
    private(set) var isVisible = false
    private(set) var returnKeyType: UIReturnKeyType = .default
    private(set) var offersAutoFillSwitch = false
    private(set) var emojiSystemSwitcher = false
    private(set) var keyboardType: UIKeyboardType = .default
    private(set) var autocapitalization: AutoCapitalizationType = .none
    private(set) var enablesReturnKeyAutomatically = false
    private(set) var hasText = false
    /// The field's keyboard appearance as an interface style (`.unspecified`: follow the system).
    private(set) var appearance: UIUserInterfaceStyle = .unspecified
    /// A line above the keys: the Full Access explainer, or the "tap again to open" fallback.
    private(set) var hint: String?
    /// Recovery guidance survives Safari's accessory-field keyboard disappearance/appearance and transient hints.
    private(set) var liveRecoveryNotice: String?
    /// Up to three suggestions, best first; the word row shows them as "2 | 1 | 3" (``SuggestionSlots``).
    /// `SuggestionController` fills them.
    var suggestions: [String] = []
    /// The first spelling proposal, if any; emphasis describes its kind, never model confidence.
    var highlightedSuggestionRank: Int?
    /// Whether to show the globe key (`needsInputModeSwitchKey`); set by the extension.
    var showsGlobe = false
    /// The id of the request the mic key's Link carries (the Darwin request uses the same id).
    private(set) var openAppRequestID = UUID().uuidString
    /// The versions of the last dictation that landed in this field (raw, cleaned, refinements), for the
    /// version keys; nil when there is none (a new run, the user typed, another field).
    private(set) var versions: DictationVersions?
    /// A refine request is waiting for the app.
    private(set) var isRefining = false
    /// The texts of the last dictation (raw, cleaned, refinements). Unlike `versions` they survive typing: the
    /// word row's alternatives come from them as long as the dictated words are in the field.
    @ObservationIgnored private(set) var lastDictationTexts: [String] = []
    /// The last dictation's versions, kept while the user types (`versions` is dropped then): undoing the
    /// typing makes a version swap possible again, and the swap is guarded by what the field holds.
    @ObservationIgnored private var keptVersions: DictationVersions?
    /// The version of the last dictation the field holds, when known.
    var shownVersionIndex: Int? { (versions ?? keptVersions)?.current }
    /// The keyboard's own edits, for ↶ ↷ (`EditHistory`); `undoAvailable` and `redoAvailable` mirror it for the views.
    @ObservationIgnored private var history = EditHistory()
    private(set) var undoAvailable = false
    private(set) var redoAvailable = false
    @ObservationIgnored private var lastDocumentID: String?
    /// Fills the word row (completions, predictions, alternatives) and learns from typing.
    @ObservationIgnored private(set) var wordRow: SuggestionController!

    /// Strip or full keyboard, and the chevron that switches; restores the last user choice.
    private(set) var expansion = KeyboardExpansion(stripEnabled: false)
    /// The strip's height in points; the debug long press steps it through `StripHeight.candidates`.
    private(set) var stripHeight = StripHeight.standard
    /// The extension re-sizes its view when the mode or the strip height changed (`reason` is for the log).
    @ObservationIgnored var onLayoutChange: (@MainActor (_ reason: String) -> Void)?
    @ObservationIgnored private let preferences: () -> KeyboardPreferences

    @ObservationIgnored private var cursor: AppliedCursor?
    /// The one writer of the field (see the type's comment), and the field it belongs to.
    @ObservationIgnored private var queue = FieldQueue()
    @ObservationIgnored private var queueDocumentID: String?
    @ObservationIgnored private var pumping = false
    /// Completions of the user's edits (word row, undo, versions) and of instruction edits, by edit id.
    @ObservationIgnored private var editCompletions: [String: (FieldQueue.Event?) -> Void] = [:]
    /// The host-state edit already handed to the queue.
    @ObservationIgnored private var enqueuedHostEditID: String?
    @ObservationIgnored private var journal = EditJournalFile()
    @ObservationIgnored private var lastJournaledReport: FieldQueue.Report?
    /// When the field counts as emptied by the host (a chat app's Send): a cleared field right after this
    /// keyboard's own edit is looked at again once the field's context has caught up (`clearRecheck`).
    @ObservationIgnored private var clearWatch = ClearWatch()
    @ObservationIgnored private var clearRecheck: Task<Void, Never>?
    /// Proposes the host's text a few characters at a time; the queue lands it. `ticker` drives both while work is left.
    @ObservationIgnored private var reveal = TypewriterReveal()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var isTornDown = false
    private var forcedOpenAppUntil: Date?
    private var remoteRequestID: String?
    private var pendingRemoteStartID: String?
    #if DEBUG
    @ObservationIgnored var beforeStartWatch: (@MainActor () async -> Void)?
    #endif
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var reapply: Task<Void, Never>?
    @ObservationIgnored private var hintTimeout: Task<Void, Never>?

    init(
        document: any TextDocument, link: LinkClient, hasFullAccess: @escaping @MainActor () -> Bool,
        preferences: @escaping () -> KeyboardPreferences = { .load() },
        expansionPersistence: KeyboardExpansionPersistence? = nil
    ) {
        self.document = document
        self.link = link
        self.hasFullAccess = hasFullAccess
        self.preferences = preferences
        let current = preferences()
        expansion = KeyboardExpansion(
            stripEnabled: current.strip,
            persistence: expansionPersistence ?? KeyboardPreferences.expansionPersistence())
        stripHeight = current.stripHeight
        emojiSystemSwitcher = current.emojiSystemSwitcher
        cursor = link.readApplied()
        host = link.readHost()
        link.observeHost { [weak self] in self?.hostDidChange() }
        link.observeComposer { [weak self] in self?.composerNoteArrived() }
        link.observeLiveDictation { [weak self] in self?.receiveLiveDictation() }
        link.observeInstruction { [weak self] in self?.receiveInstruction() }
        typing = TypingModel(controller: self)
        wordRow = SuggestionController(controller: self)
    }

    var fullAccess: Bool { hasFullAccess() }

    // MARK: Strip

    var mode: KeyboardMode { expansion.mode }

    /// Re-reads the strip setting. Turning it on or off starts a session over (collapsed with it on); the
    /// strip height comes from the setting only then, so the debug long press survives the keyboard
    /// appearing again.
    func refreshPreferences() {
        let current = preferences()
        if emojiSystemSwitcher != current.emojiSystemSwitcher {
            emojiSystemSwitcher = current.emojiSystemSwitcher
            typing?.closeEmojiPanel()
        }
        let changed = expansion.stripEnabled != current.strip
        let previousMode = expansion.mode
        expansion.setStripEnabled(current.strip)
        if changed { stripHeight = current.stripHeight }
        guard changed || previousMode != expansion.mode else { return }
        typing?.closeEmojiPanel()
        onLayoutChange?(changed ? "setting" : "restored")
    }

    /// The chevron: strip to full keyboard and back.
    func toggleExpansion() {
        guard expansion.control != nil else { return }
        typing.closeEmojiPanel()
        expansion.toggle()
        trace?("expansion mode=\(expansion.mode == .strip ? "strip" : "full")")
        onLayoutChange?("toggle")
    }

    /// A finished drag on the strip or the top bar: toggles when `KeyboardExpansion.swipeToggles` says so.
    func swiped(dx: Double, dy: Double) {
        if expansion.swipeToggles(dx: dx, dy: dy) { toggleExpansion() }
    }

    #if DEBUG
    /// Debug: a long press on the strip's word row steps the strip height through the candidates.
    func cycleStripHeight() {
        stripHeight = StripHeight.next(after: stripHeight)
        onLayoutChange?("cycle")
    }
    #endif

    /// What the keyboard says in the word row's place while it is active: a hint, else the meeting notice or
    /// the dictation status (`dictationStatus`); nil when there is nothing to say.
    var statusText: String? {
        liveRecoveryNotice ?? hint ?? instructionPresentation?.text ?? meetingNotice ?? takeStatus ?? dictatingStatus ?? dictationStatus
    }
    func dismissLiveRecovery() {
        liveRecoveryDismissed = true
        liveRecoveryNotice = nil
        syncRowTakeover()
    }

    /// The held take's phase while one is held (`cleaning`, `failed`), else nil.
    private var takePhase: String? {
        guard let phase = composer.dictationTakePhase, phase != "buffering" else { return nil }
        return phase
    }
    /// A failed take cleanup: the word row offers Retry and Insert as-is.
    var takeFailed: Bool { takePhase == "failed" }
    /// The countdown rim over the word row (after-a-pause mode), host uptime.
    var takeCountdown: (start: Double, deadline: Double)? {
        guard let start = composer.dictationCountdownStart, let deadline = composer.dictationCountdownDeadline else { return nil }
        return (start, deadline)
    }
    /// The take's cleanup runs, or failed and holds the raw text: the word row says so.
    private var takeStatus: String? {
        switch takePhase {
        case "cleaning": return "Cleaning…"
        case "failed": return "Couldn't clean up. Text held."
        default: return nil
        }
    }
    func retryTake() { composerIntent("dictation-retry") }
    func insertTakeRaw() { composerIntent("dictation-insert-raw") }

    /// While dictating: the take held so far plus the live tail take the word row's place.
    private var dictatingStatus: String? {
        guard routeOpen else { return nil }
        // The live mode types the words into the field as they come: the row only says that it listens.
        if liveRunning { return "Listening…" }
        let tail = (composer.dictationTail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = [(composer.dictationTake ?? "").trimmingCharacters(in: .whitespacesAndNewlines), tail].filter { !$0.isEmpty }.joined(separator: " ")
        guard !spoken.isEmpty else { return "Listening…" }
        return spoken.count > 90 ? "…" + spoken.suffix(90) : spoken
    }

    /// A dictation or a Refine is running: the word row is taken over and ↶ ↷ are dimmed.
    var runActive: Bool {
        if isRefining || pendingRemoteStartID != nil { return true }
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return false }
        return host.phase != .idle || host.preparingRequestID != nil
    }

    /// Tells the word row what has taken it over (status or run), so it pauses and takes up again.
    private func syncRowTakeover() {
        wordRow.setTakeover(status: statusText, running: runActive)
    }

    /// The harness's fixed words (`LegatoHarnessSuggestions`): shown whatever is typed.
    func pinSuggestions(_ words: [String]) { wordRow.pin(words) }

    /// A slot of the word row was tapped (`rank` 0 is the best suggestion).
    func suggestionTapped(rank: Int) { wordRow.tapped(rank: rank) }
    func suggestionTap(rank: Int) -> SuggestionTap? { wordRow.tapIdentity(rank: rank) }
    func suggestionTapped(_ tap: SuggestionTap) { wordRow.tapped(tap) }

    /// While the app records a meeting dictation is blocked, and the keyboard says why instead of offering to
    /// dictate. Believed only while the app keeps beating: an app that died mid-meeting leaves the flag behind.
    var meetingNotice: String? { host?.meetingNotice(now: Date()) }

    private(set) var composer = ComposerPublication()
    /// The last dictation notice (`dictationNoticeID`) already shown; the first publication seen only sets it.
    @ObservationIgnored private var seenDictationNoticeID: Int?
    /// The presence the app follows: visibility, field and the text before the cursor that the dictated lines are
    /// cleaned against (never from a secure field), plus the magic key.
    private func writePresence(notify: Bool) {
        let context = fullAccess && !document.isSecureTextEntry ? typing.contextBefore : nil
        link.writePresence(visible: true, notify: notify, documentID: document.documentID, surface: .typing, contextBefore: context,
                           magic: magic, magicAt: magicAt)
    }
    /// The host is sending audio somewhere (`dictation` or `agent`): the mic key stops it.
    var routeOpen: Bool { (composer.audioRoute ?? "idle") != "idle" }
    @ObservationIgnored private var composerPoll: Task<Void, Never>?
    private let composerLink = UserDefaultsLinkStore().map { ComposerLink(store: LinkStore($0)) }
    @ObservationIgnored private var composerReader = ComposerPublicationReader()
    #if DEBUG || LEGATO_INTERNAL
    @ObservationIgnored private var composerWatch = ComposerPollWatch()
    private static let composerLog = Logger(subsystem: "de.gruenwald.legato", category: "keyboard-composer")
    #endif
    /// An action for the host's composer session (`stop`, `dictation-retry`, `dictation-insert-raw`).
    func composerIntent(_ action: String) {
        guard fullAccess else { show("Allow Full Access to connect to Legato."); return }
        composerLink?.send(.init(action: action))
        DarwinObserver.post(LinkChannel.Note.composerIntent)
    }
    /// One read of the stored composer publication, from the 100 ms poll and from the host's `Note.composer`.
    private func pollComposer() {
        #if DEBUG || LEGATO_INTERNAL
        let now = ProcessInfo.processInfo.systemUptime
        switch composerWatch.tick(at: now) {
        case .staleAfterNote(let age)?:
            Self.composerLog.error("composer.poll stale reason=note age=\(age, format: .fixed(precision: 1)) rev=\(self.composer.snapshot.revision) lines=\(self.composer.snapshot.lines.count) bytes=\(self.composerLink?.storedByteCount ?? -1) decodeFailBytes=\(self.composerReader.lastDecodeFailureBytes ?? 0)")
        case .loopGap(let gap)?:
            Self.composerLog.error("composer.poll stale reason=loop-gap gap=\(gap, format: .fixed(precision: 1)) rev=\(self.composer.snapshot.revision) lines=\(self.composer.snapshot.lines.count)")
        case nil: break
        }
        #endif
        guard let channel = composerLink, let value = composerReader.read(from: channel) else { return }
        #if DEBUG || LEGATO_INTERNAL
        composerWatch.delivered(at: now)
        #endif
        guard value != composer else { return }
        #if DEBUG || LEGATO_INTERNAL
        Self.composerLog.info("composer.read rev=\(value.snapshot.revision) session=\(value.sessionID ?? "-", privacy: .public) lines=\(value.snapshot.lines.count) tail=\(value.tail.count) insertion=\(value.successfulInsertionID ?? "-", privacy: .public) was=\(self.composer.snapshot.lines.count)")
        #endif
        if let id = value.dictationNoticeID, let seen = seenDictationNoticeID, id != seen, let text = value.dictationNotice {
            show(text)
        }
        seenDictationNoticeID = value.dictationNoticeID ?? seenDictationNoticeID
        composer = value; composerLink?.acknowledge(value.snapshot.revision)
        syncRowTakeover()
    }
    /// The host published: read now rather than at the next poll tick, and keep the note for the stall check.
    private func composerNoteArrived() {
        guard isVisible, !isTornDown else { return }
        #if DEBUG || LEGATO_INTERNAL
        composerWatch.noteArrived(at: ProcessInfo.processInfo.systemUptime)
        #endif
        pollComposer()
    }
    // MARK: Visibility

    /// The keyboard came on screen: beat presence once a second, and catch up with a run in progress.
    func appeared() {
        guard !isTornDown else { return }
        isVisible = true
        composerPoll?.cancel()
        // Every appearance reads the stored publication afresh, whatever bytes this reader saw before (#225).
        composerReader.reset()
        #if DEBUG || LEGATO_INTERNAL
        Self.composerLog.info("composer.poll start session=\(self.composer.sessionID ?? "-", privacy: .public) rev=\(self.composer.snapshot.revision) lines=\(self.composer.snapshot.lines.count)")
        #endif
        #if DEBUG || LEGATO_INTERNAL
        composerWatch.start(at: ProcessInfo.processInfo.systemUptime)
        #endif
        composerPoll = Task { [weak self] in
            #if DEBUG || LEGATO_INTERNAL
            defer { Self.composerLog.info("composer.poll stop cancelled=\(Task.isCancelled ? 1 : 0)") }
            #endif
            while !Task.isCancelled {
                guard let self else { return }
                self.pollComposer()
                self.receiveDictation()
                self.receiveLiveDictation()
                self.receiveInstruction()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // A live run that began before this appearance is not this keyboard's to type.
        ignoredLiveRunID = link.readLiveDictation()?.runID
        // A return from the app is a new attempt, even before the previous tap's URL-settle timer.
        openAppRequestID = UUID().uuidString
        refreshPreferences()
        refreshTraits()
        typing.appeared()
        wordRow.appeared()
        writePresence(notify: true)
        // A result, an undo or a failure from before this appearance is about a field the user has left.
        instructionStrip = link.readInstructionStrip()
        if instructionPresentation?.keystrokeAction != nil { settleInstructionRow() }
        applyPendingMagic()
        trace?("visible value=1")
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LinkChannel.presenceInterval))
                guard !Task.isCancelled, let self else { return }
                self.beat()
            }
        }
        hostDidChange()
    }

    func disappeared() {
        isVisible = false
        if let snapshot = liveSnapshot, !snapshot.complete || snapshot.version != liveAckedVersion || !queue.isIdle {
            // Safari's Next/Previous accessory can cycle keyboard visibility before the new field reports its ID.
            // Remember only this controller's known interrupted take; an arbitrary old publication is still ignored.
            blockLiveRun(snapshot)
        }
        fieldOperationCancelled = true
        if let id = activeInstructionID { link.cancelInstruction(id) }
        // Nothing is left on its way to a field the keyboard no longer sees: pending edits report as dropped.
        resetQueue(reason: "hidden")
        composerPoll?.cancel(); composerPoll = nil
        remoteRequestID = nil
        pendingRemoteStartID = nil
        stopTicker()
        isVisible = false
        magic = .off
        sessionSpan.broken()
        wordRow.interruptTyping()
        typing.disappeared()
        heartbeat?.cancel()
        heartbeat = nil
        reapply?.cancel()
        cancelClearRecheck()
        link.writePresence(visible: false, notify: true)
        trace?("visible value=0")
    }

    /// The keyboard is going away for good (its view controller is being released): stop listening to the
    /// app and cancel everything that runs, so that a controller kept alive a moment longer by a view or a
    /// pending notification does nothing.
    func tearDown() {
        guard !isTornDown else { return }
        if isVisible { disappeared() }
        isTornDown = true
        stopTicker()
        link.stopObserving()
        heartbeat?.cancel()
        reapply?.cancel()
        cancelClearRecheck()
        hintTimeout?.cancel()
        typing.disappeared()
    }

    private func beat() {
        writePresence(notify: false)
        reloadHost()
    }

    /// The field, its traits or the cursor changed (a new field, another return key, a tap in the text): the
    /// extension's `textDidChange` and `selectionDidChange` both come here.
    func documentDidChange() {
        // A walk moves the cursor on purpose: nothing of it is the user's. The queue's own ops come back here too; it
        // reads them from the next report.
        guard !isFieldBusy else { return }
        if isVisible, !pumping { writePresence(notify: false) }
        refreshTraits()
        typing.documentChanged()
        if let versions, versions.documentID != document.documentID { self.versions = nil }
        if checkForClear() == .sent { applyHost() }
        trackContext()
        pump()
    }

    /// A new field starts over (no history, no row); a cursor move or text change the keyboard didn't make
    /// closes the typing group and what was typed so far is learned, and the word row looks at the word there.
    private func trackContext() {
        let id = document.documentID
        if id != lastDocumentID {
            sessionSpan.broken()
            // A result, an undo or a failure belongs to the field it was about.
            if lastDocumentID != nil, instructionPresentation?.keystrokeAction != nil { settleInstructionRow() }
            typing.closeEmojiPanel()
            lastDocumentID = id
            history.clear()
            keptVersions = nil
            lastDictationTexts = [] // the dictation belongs to the field it landed in
            syncHistory()
            wordRow.fieldChanged()
        }
        if wordRow.contextChanged() {
            history.cursorMoved()
            wordRow.interruptTyping()
            settleInstructionRowOnMove()
        }
        // Text typed, pasted or moved past by anything but this keyboard (a hardware keyboard, a tap): the session text no
        // longer ends at the cursor, and an instruction must read the field again rather than trust it.
        if !sessionSpan.text.isEmpty, queue.isIdle,
           !OwnEditEcho.isSame(expected: sessionSpan.text, reported: document.contextBefore) {
            sessionSpan.broken()
            trace?("session ended by a change outside the keyboard")
        }
    }

    private enum ClearCheck { case none, held, sent }

    /// Whether the host emptied the field (a chat app's Send), by `ClearWatch`: the dictation's versions are gone
    /// with it, and a Live run that is still going gets a sent boundary, which the app is told about
    /// (`link.applied`): the sent text is never cleaned again, typed or copied, and the rest of the run streams
    /// into the empty field (`.sent`). An empty field right after this keyboard's own edit is looked at again
    /// when the field's context has caught up; till then nothing of the run is typed (`.held`).
    @discardableResult
    private func checkForClear() -> ClearCheck {
        let outcome = clearWatch.check(
            state: host, cursor: reveal.cursorBeforeFieldClear(fallback: cursor), documentID: document.documentID, contextBefore: document.contextBefore,
            hasText: document.hasText, now: Date())
        switch outcome {
        case .notCleared:
            cancelClearRecheck()
            return .none
        case .recheck(let at):
            scheduleClearRecheck(at: at)
            return clearWatch.holds ? .held : .none
        case .cleared(let sent):
            return takeClear(sent)
        }
    }

    /// The field was emptied: the dictation's versions are gone with it; a sent boundary is recorded and told.
    /// The history goes with them only when the host emptied the field: after the keyboard's own edit (undo of the
    /// first word, a held delete, undoing a dictation) it is still good, and redo is exactly what is wanted.
    private func takeClear(_ sent: AppliedCursor?) -> ClearCheck {
        cancelClearRecheck()
        sessionSpan.broken() // the session's text left with the cleared field
        if versions?.documentID == document.documentID { versions = nil }
        if clearWatch.hostEmptiedField {
            history.clear()
            keptVersions = nil
        }
        syncHistory()
        guard let sent else { return .none }
        cursor = sent
        link.writeApplied(sent, notify: true)
        trace?("sent at=\(sent.sentBase) shown=\(sent.sentShownRevision) tentative=\(sent.sentTentative.count)")
        return .sent
    }

    /// A key is about to land: a clear held for its recheck is taken first, from the field as it is before the
    /// key (`ClearWatch.resolveHeld`), so the key cannot hide the host's Send.
    private func resolveHeldClear() {
        guard clearWatch.holds else { return }
        let outcome = clearWatch.resolveHeld(
            state: host, cursor: reveal.cursorBeforeFieldClear(fallback: cursor), documentID: document.documentID, contextBefore: document.contextBefore,
            hasText: document.hasText)
        switch outcome {
        case .cleared(let sent): _ = takeClear(sent)
        case .notCleared: cancelClearRecheck()
        case .recheck: break
        }
    }

    /// Looks at the field again at `at`, then carries on with the host's text (held back meanwhile).
    private func scheduleClearRecheck(at: Date) {
        clearRecheck?.cancel()
        clearRecheck = Task { [weak self] in
            let ms = max(0, at.timeIntervalSinceNow * 1000) + 5
            try? await Task.sleep(for: .milliseconds(Int(ms.rounded(.up))))
            guard !Task.isCancelled, let self, !self.isTornDown else { return }
            self.clearRecheck = nil
            self.trace?("sent recheck")
            self.checkForClear()
            self.applyHost()
        }
    }

    private func cancelClearRecheck() {
        clearRecheck?.cancel()
        clearRecheck = nil
    }

    /// Reads the field's traits; only changed values are stored, so the keys redraw only when needed.
    func refreshTraits() {
        offersAutoFillSwitch = AutoFillHandoff.offersAction(contentType: AutoFillContentType.semanticName(for: document.textContentType))
        if returnKeyType != document.returnKeyType { returnKeyType = document.returnKeyType }
        if keyboardType != document.keyboardType { keyboardType = document.keyboardType }
        let capitalization = AutoCapitalizationType(rawValue: document.autocapitalizationType.rawValue) ?? .none
        if autocapitalization != capitalization { autocapitalization = capitalization }
        if enablesReturnKeyAutomatically != document.enablesReturnKeyAutomatically {
            enablesReturnKeyAutomatically = document.enablesReturnKeyAutomatically
        }
        if hasText != document.hasText { hasText = document.hasText }
        let style: UIUserInterfaceStyle =
            switch document.keyboardAppearance {
            case .dark: .dark
            case .light: .light
            default: .unspecified
            }
        if appearance != style { appearance = style }
    }

    // MARK: Host state

    private func reloadHost() {
        now = Date()
        let latest = link.readHost()
        if latest != host { host = latest }
        syncRowTakeover()
    }

    private func hostDidChange() {
        guard !isTornDown else { return }
        reloadHost()
        #if DEBUG
        if let host, let insertAt = host.insertAt {
            let latency = Int((Date().timeIntervalSince(insertAt) * 1000).rounded())
            WakeProbeLog.log(
                "recv", "run=\(host.runID?.prefix(8) ?? "-") seq=\(host.seq) latencyMs=\(latency) visible=\(isVisible ? 1 : 0)")
        }
        #endif
        applyHost()
    }

    /// Brings the field in line with the host's text, when `HostApplyDecision` says so: only while visible,
    /// only for a run the app marked for the keyboard, and for a run this keyboard never followed only when
    /// its final text was asked for (the Live Activity's Insert). The last state of any other run it never
    /// saw (an old dictation, seen again when the keyboard reappears) is not typed. A "running" state whose
    /// beat has gone stale belongs to an app that died: its text is not typed either.
    ///
    /// `TypewriterReveal` proposes the text a little at a time against the queue's view of the field; the queue
    /// lands each proposal and says when (`hostEditLanded`). `flush` (and Reduce Motion) proposes it all now;
    /// `userLane`: the proposal goes ahead of later keys (text the user's key must come after).
    private func applyHost(elapsedMs: Double = 0, flush: Bool = false, userLane: Bool = false) {
        guard !isTornDown else { return }
        let decision = HostApplyDecision.decide(
            host: host, cursor: cursor, visible: isVisible, documentID: document.documentID, now: Date())
        guard case .apply = decision, let host, checkForClear() != .held else {
            #if DEBUG
            if case .skip(let reason) = decision, host?.insertAt != nil {
                WakeProbeLog.log("skip", "run=\(host?.runID?.prefix(8) ?? "-") reason=\(reason.rawValue)")
            }
            #endif
            return
        }
        syncQueueField()
        let before = cursor
        let plan = reveal.plan(
            state: host, cursor: cursor, contextBefore: queueContextBefore, documentID: document.documentID,
            animated: !flush && !UIAccessibility.isReduceMotionEnabled, elapsedMs: elapsedMs,
            hasSelection: document.selectedText?.isEmpty == false)
        if let edit = reveal.pendingEdit, edit.id != enqueuedHostEditID {
            enqueuedHostEditID = edit.id
            enqueue(edit, user: userLane)
        }
        if let updated = plan.cursor, updated != before {
            cursor = updated
            link.writeApplied(updated, notify: elapsedMs == 0 || updated.finalApplied)
        }
        updateVersions(host)
        startTickerIfNeeded()
    }

    /// The queue landed (or dropped) the host's proposal: its cursor is acknowledged, the next proposal may come.
    private func hostEditLanded(_ id: String, applied: Bool) {
        guard let host else { return }
        let updated = applied ? reveal.landed(id) : reveal.dropped(id, state: host, cursor: cursor)
        guard let updated else { return }
        let before = cursor
        cursor = updated
        link.writeApplied(updated, notify: true)
        if updated.finalApplied || before?.runID != updated.runID {
            trace?("apply final=\(updated.finalApplied ? 1 : 0) replaced=\(updated.finalReplaced.map { $0 ? "1" : "0" } ?? "-")")
        }
        #if DEBUG
        if host.insertAt != nil, updated.finalApplied {
            WakeProbeLog.log("insert", "run=\(host.runID?.prefix(8) ?? "-") final=1")
        }
        #endif
        updateVersions(host)
        applyHost()
    }

    /// A new run drops the last dictation's versions; a run that landed here offers its own.
    private func updateVersions(_ host: HostState) {
        if host.phase != .idle {
            if versions != nil, host.runID != versions?.runID { versions = nil }
            if keptVersions != nil, host.runID != keptVersions?.runID { keptVersions = nil }
            return
        }
        guard host.isFinal, versions?.runID != host.runID, keptVersions?.runID != host.runID,
              let landed = DictationVersions.landed(state: host, cursor: cursor)
        else { return }
        versions = landed
        keptVersions = landed
        lastDictationTexts = landed.texts
        recordDictation(landed)
        trace?("versions count=\(landed.texts.count) current=\(landed.current)")
    }

    /// A dictation is one entry of the history, and its cleanup (the field showing a later version than the
    /// raw text) another: undo steps from the cleaned text to the raw text, then removes the dictation.
    private func recordDictation(_ landed: DictationVersions) {
        let raw = landed.texts[0] + landed.trailing
        if !raw.isEmpty { history.record(removed: "", inserted: raw, at: Date()) }
        if landed.texts.count > 1, landed.current != 0 { history.recordVersion(from: 0, to: landed.current, at: Date()) }
        syncHistory()
    }

    // MARK: Field queue

    /// How often the ticker runs. Every op is a cross-process call to the host app, so this stays well under the
    /// display rate; the queue paces its ops itself.
    private static let tickInterval = Duration.milliseconds(33)

    /// The text before the user's cursor as the queue will leave it: what producers (typed lines, host text) plan against.
    private var queueContextBefore: String { queue.seeded ? queue.projectedBefore : shown(document.contextBefore) }

    private var currentReport: FieldQueue.Report {
        .init(before: shown(document.contextBefore), after: shown(document.contextAfter), selected: document.selectedText)
    }

    /// The queue belongs to the field the keyboard edits now: a new field starts it over (what was pending for the old
    /// one is dropped and reported), and its settings follow the field.
    private func syncQueueField() {
        let id = document.documentID
        if id != queueDocumentID {
            if queueDocumentID != nil {
                if let snapshot = liveSnapshot, liveDocumentID != id { blockLiveRun(snapshot) }
                resetQueue(reason: "field")
            }
            queueDocumentID = id
            journal.write(.init(t: Self.uptimeMs, kind: .field, field: id))
        }
        queue.config.animated = !UIAccessibility.isReduceMotionEnabled
        queue.config.movesByCharacters = charactersField != nil && charactersField == id
        queue.config.capitalization = autocapitalization
    }

    /// Drops everything pending (each edit's owner hears that it was dropped) and forgets the model.
    private func resetQueue(reason: String) {
        queue.reset()
        enqueuedHostEditID = nil
        var entry = EditJournal.Entry(t: Self.uptimeMs, kind: .reset, field: queueDocumentID)
        entry.reason = reason
        journal.write(entry)
        handle(queue.drainEvents())
        lastJournaledReport = nil
    }

    private func enqueue(_ input: FieldQueue.Input) {
        syncQueueField()
        queue.enqueue(input)
        var entry = EditJournal.Entry(t: Self.uptimeMs, kind: .input, field: queueDocumentID)
        entry.input = input
        journal.write(entry)
    }

    private func enqueue(_ edit: FieldQueue.Edit, user: Bool = false, completion: ((FieldQueue.Event?) -> Void)? = nil) {
        syncQueueField()
        if let completion { editCompletions[edit.id] = completion }
        queue.enqueue(edit, user: user)
        var entry = EditJournal.Entry(t: Self.uptimeMs, kind: .edit, field: queueDocumentID)
        entry.edit = edit; entry.user = user
        journal.write(entry)
    }

    private func enqueue(_ snapshot: LiveDictationSnapshot) {
        syncQueueField()
        queue.enqueue(snapshot)
        var entry = EditJournal.Entry(t: Self.uptimeMs, kind: .live, field: queueDocumentID)
        entry.run = snapshot.runID; entry.snapshot = snapshot
        journal.write(entry)
    }

    private static var uptimeMs: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Steps the queue against the field's report and carries out the op it hands over. Not reentrant (the field's
    /// change notes during an op come back here); paused while a walk reads the field.
    private func pump(elapsedMs: Double = 0) {
        guard !isTornDown, isVisible, !isFieldBusy, !pumping, document.documentID != nil, !document.isSecureTextEntry else { return }
        pumping = true
        defer { pumping = false }
        syncQueueField()
        var elapsed = elapsedMs
        for _ in 0..<8 {
            let report = currentReport
            let action = queue.step(report: report, elapsedMs: elapsed)
            elapsed = 0
            let events = queue.drainEvents()
            if report != lastJournaledReport || !events.isEmpty {
                var entry = EditJournal.Entry(t: Self.uptimeMs, kind: .step, field: queueDocumentID)
                entry.report = report
                entry.action = switch action { case .send: "send"; case .wait: "wait"; case .idle: "idle" }
                journal.write(entry)
                lastJournaledReport = report
            }
            handle(events)
            guard case .send(let op) = action else { break }
            switch op {
            case .move(let units): document.adjustTextPosition(byCharacterOffset: units)
            case .deleteBackward(let count): for _ in 0..<count { document.deleteBackward() }
            case .insert(let text): document.insert(text)
            }
        }
        if let open = queue.openRegion { sessionSpan.track(runID: open.runID, anchor: open.anchor, region: open.text) }
        startTickerIfNeeded()
    }

    /// What the queue reports: acknowledgements, drops and the live run's progress go to their owners.
    private func handle(_ events: [FieldQueue.Event]) {
        guard !events.isEmpty else { return }
        journal.write(EditJournal.entries(for: events, t: Self.uptimeMs, field: queueDocumentID))
        for event in events {
            switch event {
            case .sent(_, let lane):
                clearWatch.ownEdit(at: Date())
                liveStats.applies += lane == .live ? 1 : 0
                if lane != .user {
                    // The keyboard's own text is no typing: what was typed so far is learned, the tracked context is gone.
                    history.cursorMoved()
                    wordRow.interruptTyping()
                    typing.hostEdited()
                }
                if lane == .live { versions = nil }
            case .confirmed(let waited):
                if waited > 0 { liveStats.waits += 1 }
            case .resync(let kind):
                if kind == .reseeded || kind == .cursorMoved {
                    // The user moved on (or the host changed the field): the typed line stops where it is.
                    interruptDictation()
                    sessionSpan.broken()
                }
                if kind == .reseeded { liveStats.drifts += 1; liveStats.lastDrift = kind.rawValue }
                trace?("queue resync=\(kind.rawValue)")
            case .nudged, .insertedBehind:
                break
            case .applied(let id, _):
                if let completion = editCompletions.removeValue(forKey: id) { completion(event) }
                else if id == enqueuedHostEditID { enqueuedHostEditID = nil; hostEditLanded(id, applied: true) }
            case .dropped(let drop):
                trace?("queue dropped reason=\(drop.reason.rawValue) kind=\(drop.kind?.rawValue ?? "live")")
                if let completion = editCompletions.removeValue(forKey: drop.id) { completion(event) }
                else if drop.id == enqueuedHostEditID { enqueuedHostEditID = nil; hostEditLanded(drop.id, applied: false) }
                else if drop.runID != nil, drop.reason != .reset {
                    // Dictated words the field could not take (the user changed the text there): the take is in History.
                    liveRecoveryDismissed = false
                    liveRecoveryNotice = "Some dictated words couldn't be placed. Recover the take in History."
                    syncRowTakeover()
                }
            case .liveApplied(let runID, let version, let complete):
                guard runID == liveSnapshot?.runID, version != liveAckedVersion else { break }
                liveAckedVersion = version
                writeLiveAck(version: version, complete: complete)
            case .regionStarted(_, let anchor):
                liveStats.lastStart = "anchor=\(anchor)"
                writeLiveAck(version: nil, complete: false)
            case .regionClosed(_, let cause):
                liveStats.freezes += 1; liveStats.lastFreeze = cause.rawValue
                if cause != .edit { sessionSpan.broken() }
                trace?("live region closed cause=\(cause.rawValue)")
            }
        }
    }

    private func startTickerIfNeeded() {
        let needed = !queue.isIdle || reveal.needsTicks || typist.needsTicks
        guard needed, !isTornDown, isVisible else { return stopTicker() }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                let now = clock.now
                let elapsed = Self.milliseconds(now - last)
                last = now
                self.tick(elapsedMs: elapsed)
            }
        }
    }

    private func tick(elapsedMs: Double) {
        if reveal.needsTicks { applyHost(elapsedMs: elapsedMs) }
        if typist.needsTicks { dictationStep(elapsedMs: elapsedMs) }
        cancelRevokedInstructionEdits()
        pump(elapsedMs: elapsedMs)
        if queue.isIdle, !reveal.needsTicks, !typist.needsTicks { stopTicker() }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Dictation

    /// Lines the app cleaned, typed one by one (`DictationTypist`, through the queue); acknowledged on the link as they finish.
    @ObservationIgnored private var typist = DictationTypist()
    @ObservationIgnored private var lastDictation: DictationPublication?

    /// Called with the composer poll: a new publication of lines joins the queue.
    private func receiveDictation() {
        guard let publication = link.readDictation(), publication != lastDictation else { return }
        lastDictation = publication
        typist.accept(publication, acknowledged: link.readDictationAck())
        dictationStep(elapsedMs: 0)
    }

    /// A key, a completion or a cursor move: the rest of the line being typed is dropped and the following lines go
    /// in at the new cursor. (A live run's region is closed by the queue itself.)
    private func interruptDictation() {
        guard let upTo = typist.interrupt() else { return }
        acknowledgeDictation(upTo: upTo)
        trace?("dictation interrupted")
    }

    private func acknowledgeDictation(upTo: Int) {
        guard let sessionID = typist.sessionID else { return }
        link.writeDictationAck(.init(sessionID: sessionID, upTo: upTo))
    }

    private func dictationStep(elapsedMs: Double, flush: Bool = false) {
        guard !isTornDown, typist.needsTicks, document.documentID != nil else { return }
        syncQueueField()
        // The typist plans against the field as the queue will leave it (its own inserts included), so a cursor move
        // shows as a context that is not its echo.
        let context = queueContextBefore
        let step = flush
            ? typist.flush(contextBefore: context, capitalization: autocapitalization)
            : typist.step(contextBefore: context, elapsedMs: elapsedMs, capitalization: autocapitalization,
                          animated: !UIAccessibility.isReduceMotionEnabled)
        if step.deletes > 0 {
            // A failed take's partial text, taken back (the typist saw the field still end with exactly that).
            let expected = String(context.dropLast(step.deletes))
            wordRow.willApplyOwnEdit(expectedContextBefore: expected)
            enqueue(FieldQueue.Edit(kind: .typist, before: String(context.suffix(step.deletes)), target: ""))
            typing.ownEdit(contextBefore: expected)
            versions = nil
        }
        if !step.inserts.isEmpty {
            let text = step.inserts.joined()
            let expected = String(context.dropLast(step.deletes)) + text
            wordRow.willApplyOwnEdit(expectedContextBefore: expected)
            enqueue(FieldQueue.Edit(kind: .typist, target: text, atCursor: true))
            typing.ownEdit(contextBefore: expected)
            versions = nil
        }
        if let upTo = step.acknowledged { acknowledgeDictation(upTo: upTo) }
        pump()
    }

    // MARK: Live dictation

    /// The send mode `live`: the app publishes where the run's text should stand (`LiveDictationSnapshot`); the queue
    /// types it at its region's end and lands revisions as minimal edits. A key or a cursor move closes the region and
    /// later words start at the cursor; nothing freezes.
    @ObservationIgnored private var liveSnapshot: LiveDictationSnapshot?
    @ObservationIgnored private var liveSeen: LiveDictationSnapshot?
    @ObservationIgnored private var ignoredLiveRunID: String?
    @ObservationIgnored private var liveDocumentID: String?
    @ObservationIgnored private var liveStats = LiveDictationStats()
    @ObservationIgnored private var liveAckedVersion: Int?
    @ObservationIgnored private var blockedLiveRunID: String?
    @ObservationIgnored private var blockedLiveCompleted = false
    @ObservationIgnored private var liveRecoveryDismissed = false
    /// A live run is being typed (the word row says "Listening…" instead of the words).
    private(set) var liveRunning = false

    /// From the 100 ms poll and the app's note: a new snapshot of the run.
    private func receiveLiveDictation() {
        guard !isTornDown else { return }
        guard let snapshot = link.readLiveDictation() else {
            if liveSeen != nil { liveSeen = nil; liveSnapshot = nil; setLiveRunning(false) }
            return
        }
        guard snapshot != liveSeen else { return }
        if snapshot.runID == blockedLiveRunID {
            liveSeen = snapshot
            if snapshot.complete, !blockedLiveCompleted {
                blockedLiveCompleted = true
                if !liveRecoveryDismissed {
                    liveRecoveryNotice = "Recover full take in History."
                    syncRowTakeover()
                }
            }
            return
        }
        guard snapshot.runID != ignoredLiveRunID else { return }
        liveSeen = snapshot
        blockedLiveRunID = nil; blockedLiveCompleted = false
        if snapshot.runID != liveSnapshot?.runID {
            dismissLiveRecovery()
            liveStats = LiveDictationStats(); liveAckedVersion = nil
            liveDocumentID = document.documentID
            trace?("live run start")
        }
        liveSnapshot = snapshot
        setLiveRunning(!snapshot.complete)
        guard document.documentID == liveDocumentID else {
            // A late final or cleanup belongs to the field the take started in: it is recovered from History.
            return blockLiveRun(snapshot)
        }
        guard isVisible, !document.isSecureTextEntry else { return }
        enqueue(snapshot)
        pump()
    }

    /// The run stops here: what it typed stays, nothing more of it is typed, and the take is recovered from History.
    private func blockLiveRun(_ snapshot: LiveDictationSnapshot) {
        let pending = !snapshot.complete || snapshot.version != liveAckedVersion
        blockedLiveRunID = snapshot.runID
        blockedLiveCompleted = snapshot.complete
        queue.cancelRun(snapshot.runID)
        handle(queue.drainEvents())
        liveSnapshot = nil
        setLiveRunning(false)
        guard pending else { return }
        liveRecoveryDismissed = false
        liveRecoveryNotice = snapshot.complete ? "Recover full take in History." : "Finish dictation; recover in History."
        syncRowTakeover()
    }

    #if DEBUG
    /// Debug harness: the field is cleared; the live run typed into it is no longer this keyboard's to edit.
    func debugForgetLiveRun() { forgetLiveRun() }
    #endif

    /// The live run is no longer this keyboard's to edit: what it typed stays, and nothing more of it is typed.
    private func forgetLiveRun() {
        if let runID = liveSnapshot?.runID { queue.cancelRun(runID); handle(queue.drainEvents()) }
        ignoredLiveRunID = liveSnapshot?.runID ?? ignoredLiveRunID
        liveSnapshot = nil; liveSeen = nil
        setLiveRunning(false)
    }

    private func setLiveRunning(_ value: Bool) {
        guard liveRunning != value else { return }
        liveRunning = value
        syncRowTakeover()
    }

    private func writeLiveAck(version: Int?, complete: Bool) {
        guard let runID = liveSnapshot?.runID else { return }
        link.writeLiveDictationAck(.init(runID: runID, version: version, complete: complete, stats: liveStats))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    /// Before a walk moves the cursor to read the field: the queue pauses, lands the op in flight and brings the caret
    /// back to the user's cursor (bounded). The walk then has the cursor to itself; `resumeQueue` lets the queue go on.
    private func pauseQueue(limit: Duration = .milliseconds(2500)) async -> Bool {
        queue.paused = true
        let clock = ContinuousClock(), start = clock.now
        pump()
        while !queue.isHome, !isTornDown, isVisible, clock.now - start < limit {
            try? await Task.sleep(for: Self.tickInterval)
            pump(elapsedMs: Self.milliseconds(Self.tickInterval))
        }
        if !queue.isHome { trace?("queue pause timed out") }
        return queue.isHome
    }

    private func resumeQueue() {
        queue.paused = false
        pump()
    }

    // MARK: Instruction mode

    /// The magic key: `latched` (tapped on), `held` (while the finger is down) or `off`. The app tags speech with it and
    /// runs the instruction when it goes off; the change goes out at once with the presence.
    private(set) var magic = MagicToggle.off
    @ObservationIgnored private var magicAt: Date?
    /// What the app wants the instruction strip to show (nil: nothing published).
    private(set) var instructionStrip: InstructionStrip?
    /// The keyboard walks the field for an instruction: the cursor moves visibly. A key cancels the walk; it lands
    /// once the walk put the cursor back.
    private(set) var isReadingField = false
    /// The queue is paused and something else moves the cursor (a walk, the read's nudge): no reaction to change notes.
    private var isFieldBusy: Bool { isReadingField || isNudging }
    @ObservationIgnored private var activeInstructionID: String?
    @ObservationIgnored private var fieldOperationCancelled = false
    private var shouldCancelFieldOperation: Bool {
        fieldOperationCancelled || (activeInstructionID.map { link.instructionCancelled($0) } ?? false)
    }
    private func completeFieldOperation() { activeInstructionID = nil }
    @ObservationIgnored private var isNudging = false
    /// The field (document) that shows each paragraph break as "\n\n" but counts it as one unit (`FieldReader`).
    @ObservationIgnored private var collapsingField: String?

    /// The field (document) that moves the cursor one unit per character, an emoji included (`FieldReader`).
    @ObservationIgnored private var charactersField: String?

    /// A reader that knows what earlier reads found out about this field.
    private func reader(for field: String?) -> FieldReader {
        FieldReader(settleMilliseconds: 25, collapsesBreaks: field != nil && collapsingField == field ? true : nil,
                    movesByCharacters: field != nil && charactersField == field ? true : nil)
    }

    private func learn(_ read: FieldReader.Result, field: String?) {
        if let collapses = read.collapsesBreaks { if collapses { collapsingField = field } else if collapsingField == field { collapsingField = nil } }
        if let characters = read.movesByCharacters { if characters { charactersField = field } else if charactersField == field { charactersField = nil } }
    }

    /// The host's window as instructions count it: one line break per paragraph break in a `<p>` field.
    private func shown(_ window: String) -> String {
        collapsingField != nil && collapsingField == document.documentID ? FieldReader.collapsed(window) : window
    }

    /// Makes the host report the field as it is now, before a read (the queue is paused). Safari keeps the context it
    /// last reported to the keyboard when text comes in another way (a hardware keyboard, a paste): the windows then
    /// show text that is no longer there. A move of one character and back makes it report afresh; each move is given
    /// the settle gap (the proxy shows a move before the host applied it). Not with a selection (a move would collapse it).
    @discardableResult private func refreshContext() async -> Bool {
        guard isVisible, !isTornDown, !shouldCancelFieldOperation, !Task.isCancelled else { return false }
        guard document.selectedText?.isEmpty != false else { return true }
        let id = document.documentID
        let origin = (before: shown(document.contextBefore), after: shown(document.contextAfter))
        guard id != nil else { return false }
        // An empty report offers no safe position to probe. In particular, never perform a blind back/forward pair.
        guard let character = origin.before.last ?? origin.after.first else { return true }
        isNudging = true
        defer { isNudging = false }
        let backward = !origin.before.isEmpty
        let units = charactersField == id ? 1 : String(character).utf16.count
        let step = backward ? -units : units
        let moved = (before: backward ? String(origin.before.dropLast()) : origin.before + String(character),
                     after: backward ? String(character) + origin.after : String(origin.after.dropFirst()))
        func settle() async { await Task.detached { try? await Task.sleep(for: .milliseconds(Int(FieldQueue.moveSettleMs))) }.value }
        func shows(_ window: (before: String, after: String)) -> Bool {
            FieldMatch.confirms(expectedBefore: window.before, expectedAfter: window.after,
                                reportedBefore: shown(document.contextBefore), reportedAfter: shown(document.contextAfter))
        }
        document.adjustTextPosition(byCharacterOffset: step)
        var landed = false
        for _ in 0..<6 {
            await settle()
            guard isVisible, !isTornDown, document.documentID == id else { return false }
            if shows(moved) { landed = true; break }
        }
        guard landed else { return false }
        document.adjustTextPosition(byCharacterOffset: -step)
        for _ in 0..<6 {
            await settle()
            guard isVisible, !isTornDown, document.documentID == id else { return false }
            if shows(origin) { return true }
        }
        return false
    }
    /// The text Legato typed in this appearance that still ends at the cursor: the instruction scope `session`.
    @ObservationIgnored private var sessionSpan = SessionSpan()
    /// What the last read showed for an instruction, so `read_more` continues from it.
    @ObservationIgnored private var fieldRead: (instructionID: String, documentID: String?, reply: FieldReadReply)?
    @ObservationIgnored private var serving = false

    /// The magic key's state changed (the key's view calls this on tap, press and release).
    func setMagicToggle(_ value: MagicToggle) {
        guard value != magic else { return }
        magic = value; magicAt = Date()
        trace?("magic value=\(value.rawValue)")
        syncRowTakeover()
        if isVisible { writePresence(notify: true) }
    }

    /// The magic key goes on (a tap latches it, a hold holds it): speech is an instruction from now on, and the mic
    /// opens if it is not open, as a tap on the mic key would. Without Full Access the app cannot hear the key.
    func engageMagic(_ value: MagicToggle) {
        guard value.isOn else { return releaseMagic() }
        guard fullAccess else { return show("Turn on Allow Full Access for Legato in Settings > General > Keyboard to give instructions.") }
        dismissLiveRecovery()
        setMagicToggle(value)
        guard !isCapturing, pendingRemoteStartID == nil else { return }
        reloadHost()
        switch micMode {
        case .remote(.start), .needsFullAccess: micTapped()
        // Opening the app takes a real tap on the mic key's link. The key stays on, and comes back on when the keyboard
        // returns from the app (a new keyboard), so the first words after the wake are the instruction, never typed.
        case .openApp:
            Self.pendingMagic = Date()
            show("Tap the mic to wake Legato. Your next words are the instruction.")
        case .remote(.stop): break
        }
    }

    /// A wand tap that had to wake the app first, kept across the keyboard's recreation (the app opens in between).
    private static var pendingMagic: Date? {
        get { UserDefaults.standard.object(forKey: "magic.pending") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "magic.pending") }
    }

    /// On appearing: a wand tap from the last two minutes that woke the app latches the key again.
    private func applyPendingMagic() {
        guard let at = Self.pendingMagic else { return }
        Self.pendingMagic = nil
        guard Date().timeIntervalSince(at) < 120, fullAccess, !magic.isOn else { return }
        setMagicToggle(.latched)
    }

    /// The magic key goes off (tapped off, or the hold let go): the app runs the instruction once its last words are in.
    /// The mic stays as it is: dictation goes on after the instruction.
    func releaseMagic() { Self.pendingMagic = nil; setMagicToggle(.off) }

    /// What the word row shows for instruction mode, nil when it shows words.
    var instructionPresentation: InstructionStripPresentation? {
        InstructionStripPresentation(strip: instructionStrip, isReadingField: isReadingField, magic: magic)
    }

    /// The first key after a result or a failure keeps (or lets go of) it, as a tap on the strip's button would.
    private func settleInstructionRow() {
        guard let action = instructionPresentation?.keystrokeAction, let strip = instructionStrip,
              settledInstructionID != strip.instructionID, fullAccess else { return }
        settledInstructionID = strip.instructionID
        instructionIntent(action)
    }
    @ObservationIgnored private var settledInstructionID: String?
    @ObservationIgnored private var instructionStripAt = Date.distantPast

    /// The user moved the cursor or selected text: a status that no longer applies goes ("Undone.", a failure with
    /// nothing to undo). A result stays (its Undo still works), and so does a row that is still working. A strip that
    /// just arrived is kept: the field's late notes for the keyboard's own read or edit are no move of the user's.
    private func settleInstructionRowOnMove() {
        guard let presentation = instructionPresentation, Date().timeIntervalSince(instructionStripAt) > 0.7 else { return }
        switch presentation.kind {
        case .undone: settleInstructionRow()
        case .failed where !presentation.showsUndo: settleInstructionRow()
        default: break
        }
    }

    /// A tap on the instruction strip: run (again), undo, accept, or dismiss what it shows.
    func instructionIntent(_ action: InstructionIntent.Action) {
        guard fullAccess else { show("Allow Full Access to use instructions."); return }
        link.sendInstructionIntent(InstructionIntent(action: action, instructionID: instructionStrip?.instructionID))
    }

    /// The app's notes and the poll: the strip, a read to serve, an edit to land.
    private func receiveInstruction() {
        guard !isTornDown else { return }
        let strip = link.readInstructionStrip()
        if strip != instructionStrip { instructionStrip = strip; instructionStripAt = Date(); syncRowTakeover() }
        guard isVisible, !serving else { return }
        // One at a time: a read never walks while an edit's ops are still landing, and the other way round.
        if let request = link.takeReadRequest() {
            serving = true
            Task { [weak self] in
                await self?.serveRead(request)
                self?.serving = false
                self?.receiveInstruction()
            }
        } else if let edit = link.takeInstructionEdit() {
            serving = true
            Task { [weak self] in
                await self?.landInstructionEdit(edit)
                self?.serving = false
                self?.receiveInstruction()
            }
        }
    }

    /// Reads the field for the app (`link.read`). The context comes from what is known without moving the cursor (the
    /// windows around it, the session's text) and walks up only when no session text exists and the field shows more.
    /// `toCap` walks up and then down (below the cursor only the host's window is known until then), to the cap in all.
    private func serveRead(_ request: FieldReadRequest) async {
        activeInstructionID = request.instructionID; fieldOperationCancelled = false
        defer { completeFieldOperation() }
        guard Date().timeIntervalSince(request.at) <= LinkChannel.requestMaxAge, let documentID = document.documentID, !document.isSecureTextEntry else {
            return link.writeReadReply(FieldReadReply(id: request.id, state: .failed, error: "No text field to read."))
        }
        // The queue lands the op in flight and brings the caret home; the read has the cursor to itself until it ends.
        // That can take longer than the app waits for a first answer: it hears that the read is under way.
        if !queue.isHome { link.writeReadReply(FieldReadReply(id: request.id, state: .reading)) }
        defer { resumeQueue() }
        guard await pauseQueue() else {
            return link.writeReadReply(FieldReadReply(id: request.id, state: .failed, error: "The field is busy. Try again in a moment."))
        }
        guard await refreshContext() else {
            return link.writeReadReply(FieldReadReply(id: request.id, state: .failed,
                error: "This app did not confirm the cursor position. Nothing was edited."))
        }
        guard document.documentID == documentID else {
            return link.writeReadReply(FieldReadReply(id: request.id, state: .failed, error: "No text field to read."))
        }
        guard !link.instructionCancelled(request.instructionID) else {
            return link.writeReadReply(FieldReadReply(id: request.id, state: .failed, error: "This instruction was cancelled."))
        }
        let before = shown(document.contextBefore), after = shown(document.contextAfter)
        let selection = document.selectedText.flatMap { $0.isEmpty ? nil : $0 }
        #if DEBUG
        WindowProbe.log("read kind=\(request.kind.rawValue) selected=\(WindowProbe.show(document.selectedText)) before=\(WindowProbe.show(before)) after=\(WindowProbe.show(after))")
        #endif
        // Below the cursor: the host's window, unverified (whether the field ends there is known only after a walk down).
        let below = String(after.prefix(FieldReader.defaultCap))
        var reply = FieldReadReply(id: request.id, state: .done, below: below, selection: selection,
                                   stopBelow: after.isEmpty ? .start : .unread, moreBelow: !after.isEmpty, documentID: documentID)
        switch request.kind {
        case .context, .contextInPlace:
            if selection != nil {
                // A walk would collapse the selection: only the windows around it, and only the selection is edited.
                reply.above = before; reply.stop = .unread; reply.moreAbove = !before.isEmpty
            } else if !sessionSpan.text.isEmpty, OwnEditEcho.isSame(expected: sessionSpan.text, reported: before) {
                let session = sessionSpan.text
                reply.above = before.count > session.count ? before : session
                reply.sessionLength = session.count
                let atStart = sessionSpan.startsField && reply.above == session
                reply.stop = atStart ? .start : .unread; reply.moreAbove = !atStart
            } else if before.isEmpty {
                reply.stop = .start
            } else if request.kind == .contextInPlace {
                // No walk: a selection the host does not report would be lost. Only the window, trusted from its start.
                reply.above = String(FieldReader.trusted(before: before)); reply.stop = .unread; reply.moreAbove = true
            } else {
                guard let read = await walk(request, run: { reader, proxy in await reader.readUp(proxy, known: "", limit: .cap) }) else { return }
                reply.above = read.text; reply.stop = read.stop; reply.moreAbove = read.moreRemains
            }
        case .more, .toCap:
            guard let last = fieldRead, last.instructionID == request.instructionID, last.documentID == documentID else {
                return link.writeReadReply(FieldReadReply(id: request.id, state: .failed, error: "The text changed while it was read."))
            }
            reply = last.reply; reply.id = request.id
            guard selection == nil else { return link.writeReadReply(reply) }
            // A stop that is not the cap's or a block's ends the text the user is working on: nothing more there to read.
            let openAbove = reply.moreAbove && [.unread, .block].contains(reply.stop)
            let openBelow = request.kind == .toCap && reply.moreBelow && [.unread, .block].contains(reply.stopBelow ?? .unread)
            if openAbove {
                let known = reply.above
                guard let read = await walk(request, run: { reader, proxy in
                    await reader.readUp(proxy, known: known, limit: request.kind == .more ? .block : .cap)
                }) else { return }
                reply.above = read.text; reply.stop = read.stop; reply.moreAbove = read.moreRemains
            }
            let room = FieldReader.defaultCap - reply.above.count
            if openBelow, room > reply.below.count {
                let known = reply.below
                guard let read = await walk(request, run: { reader, proxy in await reader.readDown(proxy, known: known, room: room) }) else { return }
                reply.below = read.text; reply.stopBelow = read.stop; reply.moreBelow = read.moreRemains
            }
        }
        guard !link.instructionCancelled(request.instructionID), document.documentID == documentID else {
            return link.writeReadReply(FieldReadReply(id: request.id, state: .failed, error: "This instruction was cancelled or the field changed."))
        }
        fieldRead = (request.instructionID, documentID, reply)
        trace?("instruction read kind=\(request.kind.rawValue) above=\(reply.above.count) stop=\(reply.stop.rawValue) below=\(reply.below.count) stopBelow=\(reply.stopBelow?.rawValue ?? "unread") session=\(reply.sessionLength)")
        link.writeReadReply(reply)
    }

    /// The self-verifying walk (`FieldReader`), with the strip's "reading" state; a failure is answered (no partial text).
    private func walk(_ request: FieldReadRequest,
                      run: (FieldReader, any FieldWindowProxy) async -> Result<FieldReader.Result, FieldReader.Failure>) async -> FieldReader.Result? {
        link.writeReadReply(FieldReadReply(id: request.id, state: .reading))
        isReadingField = true
        syncRowTakeover()
        let started = Date()
        #if DEBUG
        let windows: any FieldWindowProxy = WindowProbe.enabled ? WindowProbe(DocumentWindows(document, cancelled: { [weak self] in self?.shouldCancelFieldOperation == true }, canMove: { [weak self] in self?.isVisible == true && self?.isTornDown == false })) : DocumentWindows(document, cancelled: { [weak self] in self?.shouldCancelFieldOperation == true }, canMove: { [weak self] in self?.isVisible == true && self?.isTornDown == false })
        #else
        let windows: any FieldWindowProxy = DocumentWindows(document, cancelled: { [weak self] in self?.shouldCancelFieldOperation == true }, canMove: { [weak self] in self?.isVisible == true && self?.isTornDown == false })
        #endif
        let field = document.documentID
        let result = await run(reader(for: field), windows)
        if case .success(let read) = result { learn(read, field: field) }
        isReadingField = false
        // The cursor is back where it was: the keyboard catches up with the field once.
        documentDidChange()
        syncRowTakeover()
        switch result {
        case .success(let read):
            trace?("instruction walk ok added=\(read.added) steps=\(read.steps) rereads=\(read.rereads) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return read
        case .failure(let failure):
            trace?("instruction walk failed reason=\(String(describing: failure)) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            var reply = FieldReadReply(id: request.id, state: .failed, error: failure.message)
            reply.lasting = failure.isLasting
            link.writeReadReply(reply)
            return nil
        }
    }

    /// Lands an instruction's result (or its undo) through the queue as minimal character edits of exactly the scope,
    /// wherever that text is now (the user may have typed or moved meanwhile; the queue finds it again). Text that is
    /// gone or changed is not edited: the ack says why, and the app keeps the original and the rewrite in History.
    private func landInstructionEdit(_ edit: ScopedEdit) async {
        activeInstructionID = edit.instructionID; fieldOperationCancelled = false
        defer { completeFieldOperation() }
        guard let documentID = document.documentID, edit.documentID == nil || edit.documentID == documentID, !document.isSecureTextEntry else {
            return link.writeInstructionEditAck(ScopedEditAck(id: edit.id, applied: false, reason: "The text field changed, so nothing was edited."))
        }
        guard !link.instructionCancelled(edit.instructionID) else {
            return link.writeInstructionEditAck(ScopedEditAck(id: edit.id, applied: false, reason: "The instruction was cancelled before editing."))
        }
        let queued = FieldQueue.Edit(id: edit.id, kind: .magic, before: edit.before, after: edit.after, selected: edit.selected,
                                     target: edit.target, cursorAtEnd: edit.selected != nil, paced: true)
        let started = Date()
        let outcome: FieldQueue.Event? = await withCheckedContinuation { continuation in
            magicEditIDs[edit.id] = edit.instructionID
            enqueue(queued, completion: { continuation.resume(returning: $0) })
            pump()
            // A queue that never answers (the keyboard went away mid-edit answers with a drop) is bounded by the
            // app's own wait; a later answer is ignored.
        }
        magicEditIDs[edit.id] = nil
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        typing.hostEdited()
        versions = nil
        fieldRead = nil
        switch outcome {
        case .applied(_, let cursor)?:
            let newBefore = String(decoding: Array(edit.target.utf16.prefix(cursor)), as: UTF16.self)
            if edit.selected == nil { sessionSpan.edited(before: edit.before, newBefore: newBefore) } else { sessionSpan.broken() }
            trace?("instruction edit applied ms=\(ms) chars=\(edit.scopeText.count)->\(edit.target.count)")
            link.writeInstructionEditAck(ScopedEditAck(id: edit.id, applied: true, cursor: cursor))
        case .dropped(let drop)?:
            sessionSpan.broken()
            trace?("instruction edit dropped reason=\(drop.reason.rawValue) ms=\(ms)")
            let reason = switch drop.reason {
            case .changed, .userEdited: "The text changed, so the edit was not made. The original and rewrite are available in History."
            case .selectionChanged: "The selection changed, so nothing was edited."
            case .unplaceable: "The text could not be found again, so the edit was not made. The original and rewrite are available in History."
            case .reset: "The text field went away. The original and rewrite are available in History. Check the text."
            }
            // Partly landed: the scope as it stands now, so an undo can still put the original back.
            if let partial = drop.partial, partial != edit.scopeText {
                link.writeInstructionEditAck(ScopedEditAck(id: edit.id, applied: false, reason: reason, partial: partial, stopped: true))
            } else {
                link.writeInstructionEditAck(ScopedEditAck(id: edit.id, applied: false, reason: reason))
            }
        default:
            link.writeInstructionEditAck(ScopedEditAck(id: edit.id, applied: false, reason: "The instruction was cancelled. The original and rewrite are available in History."))
        }
        documentDidChange()
    }

    /// Instruction edits on their way, by edit id (their instruction ids): a cancelled instruction's edit leaves the queue.
    @ObservationIgnored private var magicEditIDs: [String: String] = [:]

    private func cancelRevokedInstructionEdits() {
        for (editID, instructionID) in magicEditIDs where link.instructionCancelled(instructionID) {
            magicEditIDs[editID] = nil
            queue.cancelEdit(editID)
            if let completion = editCompletions.removeValue(forKey: editID) {
                completion(nil)
            }
        }
    }

    // MARK: Cursor control

    /// A key, a pan or a word-row tap while a walk reads the field: the walk stops (and puts the cursor back), the
    /// instruction is cancelled, and the input lands after it. Nothing waits for more than that.
    private func userPreemptsFieldRead() {
        guard isFieldBusy || activeInstructionID != nil, isReadingField || isNudging else { return }
        fieldOperationCancelled = true
        if let id = activeInstructionID { link.cancelInstruction(id) }
    }

    func cursorPanBegan() {
        userPreemptsFieldRead()
        history.cursorMoved()
        wordRow.cursorPanBegan()
        syncHistory()
    }

    /// The public keyboard proxy exposes insertion offsets, not host line rectangles: the queue moves the cursor by
    /// characters within the text it knows (a selection collapses first).
    func moveCursor(by characters: Int) {
        guard characters != 0 else { return }
        userPreemptsFieldRead()
        enqueue(.move(characters))
        pump()
    }

    func cursorPanEnded() { pump() }

    // MARK: Typing

    /// A Return holds no clear back (`ClearWatch.returnTyped`): in a chat app it sends and empties the field.
    /// `contextBefore`: the text before the cursor as the typing model tracks it (the field's own report lags).
    /// The key goes to the queue's front: it lands at the user's cursor behind at most the op in flight (a word the
    /// dictation was revealing is finished in front of it). Returns false: the key itself is all that was typed.
    @discardableResult
    func type(_ text: String, contextBefore: String? = nil) -> Bool {
        versions = nil // the user moved on from the dictation
        userPreemptsFieldRead()
        interruptDictation()
        resolveHeldClear()
        beforeUserEdit()
        let before = contextBefore ?? typing.contextBefore
        let selected = document.selectedText
        enqueue(.insert(text))
        if text == "\n" { clearWatch.returnTyped(at: Date()) } else { clearWatch.ownEdit(at: Date()) }
        if let selected, !selected.isEmpty {
            history.record(removed: selected, inserted: text, at: Date(), contextBefore: before + text) // the key replaced the selection
            wordRow.interruptTyping()
        } else {
            history.typed(text, at: Date(), contextBefore: before + text)
            wordRow.typed(text)
        }
        syncHistory()
        wordRow.keystroke(contextBefore: before + text)
        pump()
        afterUserEdit()
        return false
    }

    func deleteBackward(contextBefore: String? = nil) {
        versions = nil
        userPreemptsFieldRead()
        interruptDictation()
        resolveHeldClear()
        beforeUserEdit()
        let before = contextBefore ?? typing.contextBefore
        let selected = document.selectedText
        let deletesSelection = selected?.isEmpty == false
        let remaining = deletesSelection ? before : String(before.dropLast())
        clearWatch.ownEdit(at: Date(), leavesFieldEmpty: remaining.isEmpty && document.contextAfter.isEmpty)
        enqueue(.deleteBackward)
        if let selected, deletesSelection {
            history.record(removed: selected, inserted: "", at: Date(), contextBefore: before)
            wordRow.interruptTyping()
        } else if let last = before.last {
            history.deleted(String(last), at: Date(), contextBefore: remaining)
            wordRow.deletedTyped()
        }
        syncHistory()
        wordRow.keystroke(contextBefore: remaining)
        pump()
        afterUserEdit()
    }

    /// One edit of the word row (a completion or a swap), or of undo and redo: the span around the cursor becomes
    /// `edit.insert`, as minimal character edits through the queue, ahead of later keys. `removed` is the text the edit
    /// takes out, for the history; `asTyping` marks a completion, which the row follows up with predictions and which
    /// counts as typed text. `record: false` is for undo and redo, which move the history themselves.
    func applyEdit(_ edit: WordEdit, removed: String, asTyping: Bool, record: Bool = true) {
        userPreemptsFieldRead()
        interruptDictation()
        resolveHeldClear()
        beforeUserEdit()
        let before = typing.contextBefore
        let after = document.contextAfter
        let moved = before + String(after.prefix(edit.forward))
        let expected = String(moved.dropLast(edit.deleteCount)) + edit.insert
        let old = String(moved.suffix(edit.deleteCount))
        let oldAfter = String(after.prefix(edit.forward))
        guard old.count == edit.deleteCount, oldAfter.count <= old.count else {
            show("The word changed, so nothing was edited."); return
        }
        versions = nil
        wordRow.interruptTyping()
        let queued = FieldQueue.Edit(kind: record ? .word : .undo, before: shown(String(old.dropLast(oldAfter.count))),
                                     after: shown(oldAfter), target: shown(edit.insert))
        enqueue(queued, user: true) { [weak self] outcome in
            guard let self else { return }
            guard case .applied? = outcome else {
                if !record { self.history.clear(); self.syncHistory() }
                self.show("The text changed, so nothing was edited.")
                return
            }
            if asTyping { self.wordRow.completed(deleting: edit.deleteCount, with: edit.insert) }
            self.wordRow.willApplyOwnEdit(expectedContextBefore: expected)
            if record { self.history.record(removed: removed, inserted: edit.insert, at: Date(), contextBefore: expected) }
            self.syncHistory()
            self.typing.ownEdit(contextBefore: expected)
            if asTyping || !record { self.wordRow.keystroke(contextBefore: expected) }
            self.afterUserEdit()
        }
        pump()
    }

    /// The user's choice from the word row, for the app to learn from (Full Access only).
    func recordChoice(_ record: ChoiceRecord) {
        guard hasFullAccess() else { return }
        link.writeChoice(record)
    }

    // MARK: Undo and redo

    /// ↶ ↷ undo and redo the keyboard's own edits; dimmed while a run is active.
    var canUndo: Bool { undoAvailable && !runActive }
    var canRedo: Bool { redoAvailable && !runActive }

    private func syncHistory() {
        if undoAvailable != history.canUndo { undoAvailable = history.canUndo }
        if redoAvailable != history.canRedo { redoAvailable = history.canRedo }
    }

    func undo() {
        guard canUndo else { return }
        userPreemptsFieldRead()
        prepareHistoryStep(discardingTyped: true)
        guard let step = history.undo(contextBefore: typing.contextBefore) else { return historyRefused() }
        syncHistory()
        run(step, undoing: true)
    }

    func redo() {
        guard canRedo else { return }
        userPreemptsFieldRead()
        prepareHistoryStep(discardingTyped: false)
        guard let step = history.redo(contextBefore: typing.contextBefore) else { return historyRefused() }
        syncHistory()
        run(step, undoing: false)
    }

    /// Undoing typing drops the typing buffer (what is taken back is not learned); a redo has nothing typed to lose.
    private func prepareHistoryStep(discardingTyped: Bool) {
        resolveHeldClear()
        if reveal.needsTicks { applyHost(flush: true, userLane: true) }
        if discardingTyped { wordRow.discardTyping() } else { wordRow.interruptTyping() }
    }

    /// The field changed behind the keyboard's back: the guard cleared the history.
    private func historyRefused() {
        syncHistory()
        show("The text changed, so there is nothing to undo.")
    }

    private func run(_ step: EditHistory.Step, undoing: Bool) {
        switch step {
        case .edit(let edit):
            applyEdit(edit, removed: "", asTyping: false, record: false)
        case .version(let index):
            // A swap the field no longer allows leaves the entry where it was; the rest of the history is intact.
            if !showVersion(at: index, record: false) {
                if undoing { history.revertUndo() } else { history.revertRedo() }
                syncHistory()
            }
        }
    }

    /// The user types into a run's text: the tentative text comes out first so the key lands after the
    /// committed text; `applyHost` puts it back after the key. Both go ahead of the key in the queue.
    private func beforeUserEdit() {
        dismissLiveRecovery()
        settleInstructionRow()
        // Committed text still to be revealed goes in first, so the key does not land in the middle of it.
        if reveal.needsTicks { applyHost(flush: true, userLane: true) }
        guard let current = cursor, let documentID = document.documentID, current.documentID == documentID,
              let host, host.runID == current.runID, host.phase != .idle
        else { return }
        let context = queueContextBefore
        let plan = ProxyEditPlanner.prepareForTyping(cursor: current, contextBefore: context)
        let deletes = plan.ops.reduce(0) { if case .deleteBackward(let n) = $1 { $0 + n } else { $0 } }
        if deletes > 0 {
            enqueue(FieldQueue.Edit(kind: .host, before: String(context.suffix(deletes)), target: ""), user: true)
        }
        if let updated = plan.cursor, updated != current {
            cursor = updated
            link.writeApplied(updated)
        }
    }

    /// The document's context settles a moment after an edit; planning against it right away would
    /// misjudge the separator. The next host update would do too, but it can be a while off.
    private func afterUserEdit() {
        guard cursor != nil else { return }
        reapply?.cancel()
        reapply = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.applyHost()
        }
    }

    // MARK: Mic key

    /// Whether the app is listening right now, rather than preparing resources or starting capture.
    var isCapturing: Bool {
        if composer.status == "listening" || routeOpen { return true }
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return false }
        return host.phase == .listening
    }

    /// What tapping the mic key does now.
    var micMode: MicKeyMode {
        if composer.status == "listening" { return .remote(.stop) }
        if pendingRemoteStartID != nil, hasFullAccess() { return .remote(.stop) }
        if let until = forcedOpenAppUntil, until > now, hasFullAccess() { return .openApp }
        return MicKeyMode.resolve(host: host, now: now, fullAccess: hasFullAccess())
    }

    /// What the open-app key asks of the app: to arm the microphone, not to dictate (the app is in front
    /// of the host app's field then). The dictation starts with the next tap, back in the host app.
    var openAppCommand: RequestCommand { MicKeyMode.openApp.request ?? .arm }

    /// The mic key was tapped. In `.openApp` mode the key is a `Link` that opens the app by itself; this
    /// sends the same request over the link, for an app that is already running.
    func micTapped() {
        if composer.status == "listening" || routeOpen { composerIntent("stop"); return }
        reloadHost()
        let mode = micMode
        switch mode {
        case .needsFullAccess:
            trace?("mic mode=needsFullAccess")
            show("Turn on Allow Full Access for Legato in Settings > General > Keyboard to dictate.")
        case .openApp:
            trace?("mic mode=openApp")
            let id = openAppRequestID
            link.send(openAppCommand, id: id)
            Task { [weak self] in
                let result = await self?.link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
                self?.trace?("ack result=\(result?.rawValue ?? "timeout")")
            }
            // The Link reads its URL as the tap lands; a fresh id is for the next tap.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.openAppRequestID == id else { return }
                self.openAppRequestID = UUID().uuidString
            }
        case .remote(let action):
            trace?("mic mode=remote-\(action == .start ? "start" : "stop")")
            let id = UUID().uuidString
            remoteRequestID = id
            pendingRemoteStartID = action == .start ? id : nil
            syncRowTakeover()
            Task { await sendRemote(action, id: id) }
        }
    }

    /// Asks the running app; without an ack in time (or an ack of `hop`) the key becomes an open-app
    /// key for a few seconds, because opening the app takes a real tap on the Link.
    private func sendRemote(_ action: RemoteAction, id: String) async {
        guard remoteRequestID == id else { return }
        link.send(action == .start ? .start : .stop, id: id)
        let result = await link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
        guard remoteRequestID == id, isVisible else { return }
        trace?("ack result=\(result?.rawValue ?? "timeout")")
        guard result != .accepted else {
            // "Accepted" is the app taking the request on; a start can still fail afterwards (the system
            // refused the microphone), and then the app answers the same request again with `hop`.
            if action == .start { await watchForFailedStart(id: id) }
            return
        }
        pendingRemoteStartID = nil
        needsAppOpened()
    }

    /// Watches a start the app accepted until the run is listening, or the app says it could not start.
    private func watchForFailedStart(id: String) async {
        #if DEBUG
        await beforeStartWatch?()
        #endif
        var missingHostSince: ContinuousClock.Instant?
        while remoteRequestID == id, isVisible {
            if let ack = link.readAck(), ack.id == id, ack.result == .hop {
                trace?("ack result=hop-after-accept")
                pendingRemoteStartID = nil
                needsAppOpened()
                return
            }
            reloadHost()
            if let host {
                missingHostSince = nil
                if now.timeIntervalSince(host.beatAt) >= LinkChannel.beatFreshness {
                    pendingRemoteStartID = nil
                    needsAppOpened()
                    return
                }
                if let completion = host.startCompletion, completion.requestIDs.contains(id) {
                    pendingRemoteStartID = nil
                    syncRowTakeover()
                    if completion.needsForeground { needsAppOpened() }
                    return
                }
                if host.phase == .listening {
                    pendingRemoteStartID = nil
                    syncRowTakeover()
                    return
                }
            } else {
                let instant = ContinuousClock.now
                if missingHostSince == nil { missingHostSince = instant }
                if let missingHostSince, instant - missingHostSince >= .seconds(LinkChannel.beatFreshness) {
                    pendingRemoteStartID = nil
                    needsAppOpened()
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// The app can't dictate from where it is: the mic key becomes an open-app key for a few seconds.
    private func needsAppOpened() {
        reloadHost()
        forcedOpenAppUntil = now.addingTimeInterval(5)
        openAppRequestID = UUID().uuidString
        show("Legato needs to open. Tap the mic again.")
    }

    // MARK: Versions

    /// Swaps the dictation in the field for version `index`, only while the field still ends with the
    /// version shown now. `record`: whether this is a new step of the history (Refine) rather than undo or redo.
    @discardableResult
    private func showVersion(at index: Int, record: Bool) -> Bool {
        userPreemptsFieldRead()
        guard var current = keptVersions ?? versions, current.texts.indices.contains(index) else { return false }
        let from = current.current
        guard current.documentID == document.documentID,
              let ops = current.swapOps(to: index, contextBefore: typing.contextBefore)
        else {
            trace?("version swap=refused")
            show("The text changed, so there is nothing to swap.")
            return false
        }
        let before = typing.contextBefore
        let expected = String(before.dropLast(current.shown.count)) + current.texts[index] + current.trailing
        _ = ops // swapOps validates the current version's ownership; the queue makes the minimal edits.
        let edit = FieldQueue.Edit(kind: .version, before: shown(current.shown), target: shown(current.texts[index] + current.trailing))
        enqueue(edit, user: true) { [weak self] outcome in
            guard let self else { return }
            guard case .applied? = outcome else {
                if !record { self.history.clear(); self.syncHistory() }
                self.show("The text changed, so there is nothing to swap.")
                return
            }
            self.wordRow.willApplyOwnEdit(expectedContextBefore: expected)
            self.typing.ownEdit(contextBefore: expected)
            current.show(index)
            self.versions = current
            self.keptVersions = current
            if record, from != index {
                self.history.recordVersion(from: from, to: index, at: Date())
                self.syncHistory()
            }
            self.trace?("version index=\(index) of=\(current.texts.count)")
        }
        pump()
        return true
    }

    /// Asks the app for a stronger rewrite (its message style) of the raw dictation and shows it as a new
    /// version. The keyboard never runs a model itself; the app must be running (it acks at once).
    func refine() {
        guard !isRefining else { return }
        guard hasFullAccess() else {
            show("Turn on Allow Full Access for Legato in Settings > General > Keyboard to refine.")
            return
        }
        guard let versions else {
            show("Refine works on the dictation you just made.")
            return
        }
        isRefining = true
        let id = UUID().uuidString
        let runID = versions.runID
        link.sendRefine(versions.texts[0], id: id)
        trace?("refine sent")
        Task { [weak self] in
            await self?.awaitRefinement(id: id, runID: runID)
            self?.isRefining = false
        }
    }

    private func awaitRefinement(id: String, runID: String) async {
        let ack = await link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
        guard ack == .accepted else {
            trace?("refine ack=\(ack?.rawValue ?? "timeout")")
            show("Open Legato to refine: it isn't running right now.")
            return
        }
        guard let reply = await link.awaitRefined(id: id, timeout: LinkChannel.refineTimeout) else {
            trace?("refine reply=timeout")
            show("Refine took too long.")
            return
        }
        guard let refined = reply.text else {
            trace?("refine reply=none")
            show("No better version.")
            return
        }
        guard var current = versions, current.runID == runID else { return }
        let index = current.add(refined)
        versions = current
        keptVersions = current
        lastDictationTexts = current.texts
        trace?("refine reply=text")
        showVersion(at: index, record: true)
    }

    /// Refine can run: there is a dictation to refine and Full Access lets the keyboard ask the app.
    var canRefine: Bool { versions != nil && fullAccess && !isRefining }

    // MARK: Status

    /// The top bar's dictation line: the live text while a `.hold` run listens (nothing is typed then),
    /// "Listening…" otherwise, "Cleaning up…" while a run with cleanup finishes.
    var dictationStatus: String? {
        if pendingRemoteStartID != nil, host?.phase != .starting, host?.phase != .listening { return "Preparing dictation…" }
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return nil }
        if host.preparingRequestID != nil { return "Preparing dictation…" }
        switch host.phase {
        case .starting:
            return "Starting dictation…"
        case .listening:
            let live = host.committed + host.volatile
            guard host.delivery == .hold, !live.trimmingCharacters(in: .whitespaces).isEmpty else { return "Listening…" }
            return live.count > 90 ? "…" + live.suffix(90) : live
        case .finishing:
            return host.delivery == nil ? nil : "Cleaning up…"
        case .idle:
            return nil
        }
    }

    /// Local palette by default; the configured system control receives its own UIKit touches.
    func emojiTapped() {
        guard !emojiSystemSwitcher else { return }
        typing.openEmojiPanel()
    }

    private func show(_ text: String) {
        hint = text
        syncRowTakeover()
        hintTimeout?.cancel()
        hintTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint = nil
            self?.syncRowTakeover()
        }
    }
}

/// The field's windows for `FieldReader`, over the keyboard's document.
#if DEBUG
/// Debug: logs every window the walk reads and every move (`defaults write <keyboard bundle> LegatoWindowProbe -bool YES`;
/// synthetic text only, on a simulator).
@MainActor private final class WindowProbe: FieldWindowProxy {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "LegatoWindowProbe") }
    private static let logger = Logger(subsystem: "de.gruenwald.legato", category: "probe")
    static func log(_ message: String) { guard enabled else { return }; logger.debug("\(message, privacy: .public)") }
    static func show(_ text: String?) -> String {
        guard let text else { return "nil" }
        let escaped = text.unicodeScalars.map { s -> String in
            switch s { case "\n": "<NL>"; case "\u{2029}": "<PS>"; case "\u{2028}": "<LS>"; case "\u{FFFC}": "<OBJ>"; case "\u{A0}": "<NBSP>"
            default: s.value < 32 ? String(format: "<%02X>", s.value) : String(s) }
        }.joined()
        return "\(text.utf16.count)|\(escaped)|"
    }
    private let base: any FieldWindowProxy
    init(_ base: any FieldWindowProxy) { self.base = base }
    var windowBefore: String { let w = base.windowBefore; Self.log("  before=\(Self.show(w))"); return w }
    var windowAfter: String { let w = base.windowAfter; Self.log("  after=\(Self.show(w))"); return w }
    var isCancelled: Bool { base.isCancelled }
    func move(by units: Int) { Self.log("  move \(units)"); base.move(by: units) }
    func pause(milliseconds: Int) async { await base.pause(milliseconds: milliseconds) }
}
#endif

/// The field's windows as instructions count them (`KeyboardController.shown`).
@MainActor private final class ShownWindows: FieldWindowProxy {
    private let document: any TextDocument
    private let documentID: String?
    private let shown: (String) -> String
    private let cancelled: () -> Bool
    private let canMove: () -> Bool
    var isCancelled: Bool { cancelled() }
    init(_ document: any TextDocument, shown: @escaping (String) -> String, cancelled: @escaping () -> Bool, canMove: @escaping () -> Bool) {
        self.document = document; self.documentID = document.documentID; self.shown = shown
        self.cancelled = cancelled; self.canMove = canMove
    }
    var windowBefore: String { document.documentID == documentID ? shown(document.contextBefore) : "" }
    var windowAfter: String { document.documentID == documentID ? shown(document.contextAfter) : "" }
    func move(by units: Int) {
        guard canMove(), document.documentID == documentID else { return }
        document.adjustTextPosition(byCharacterOffset: units)
    }
    func pause(milliseconds: Int) async {
        // Restoration still needs real host turns when the requesting task was cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(milliseconds)) }.value
    }
}

@MainActor private final class DocumentWindows: FieldWindowProxy {
    private let document: any TextDocument
    private let documentID: String?
    private let cancelled: () -> Bool
    private let canMove: () -> Bool
    var isCancelled: Bool { cancelled() }
    init(_ document: any TextDocument, cancelled: @escaping () -> Bool, canMove: @escaping () -> Bool) {
        self.document = document; self.documentID = document.documentID
        self.cancelled = cancelled; self.canMove = canMove
    }
    var windowBefore: String { document.documentID == documentID ? document.contextBefore : "" }
    var windowAfter: String { document.documentID == documentID ? document.contextAfter : "" }
    func move(by units: Int) {
        guard canMove(), document.documentID == documentID else { return }
        document.adjustTextPosition(byCharacterOffset: units)
    }
    func pause(milliseconds: Int) async {
        // Restoration still needs real host turns when the requesting task was cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(milliseconds)) }.value
    }
}
