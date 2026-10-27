import Foundation
import LegatoKeyboardCore
import Observation
import UIKit

/// The keyboard's brain, shared by the extension and the DEBUG harness in the app: shows the link's
/// state, turns the host's dictation text into edits of the document (`ProxyEditPlanner`), reports what
/// landed (`link.applied`), keeps the presence beat while visible and decides what the mic key does.
///
/// The planner, the typewriter reveal and the mic-key rules live in LegatoKeyboardCore and are tested
/// there; this type only carries them out against a `TextDocument` and the App Group.
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
    private(set) var keyboardType: UIKeyboardType = .default
    private(set) var autocapitalization: AutoCapitalizationType = .none
    private(set) var enablesReturnKeyAutomatically = false
    private(set) var hasText = false
    /// The field's keyboard appearance as an interface style (`.unspecified`: follow the system).
    private(set) var appearance: UIUserInterfaceStyle = .unspecified
    /// A line above the keys: the Full Access explainer, or the "tap again to open" fallback.
    private(set) var hint: String?
    /// Up to three suggestions, best first; the word row shows them as "2 | 1 | 3" (``SuggestionSlots``).
    /// `SuggestionController` fills them.
    var suggestions: [String] = []
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

    /// Strip or full keyboard, and the chevron that switches (`KeyboardExpansion`, per keyboard session).
    private(set) var expansion = KeyboardExpansion(stripEnabled: false)
    /// The strip's height in points; the debug long press steps it through `StripHeight.candidates`.
    private(set) var stripHeight = StripHeight.standard
    /// The extension re-sizes its view when the mode or the strip height changed (`reason` is for the log).
    @ObservationIgnored var onLayoutChange: (@MainActor (_ reason: String) -> Void)?
    @ObservationIgnored private let preferences: () -> KeyboardPreferences

    @ObservationIgnored private var cursor: AppliedCursor?
    /// When the field counts as emptied by the host (a chat app's Send): a cleared field right after this
    /// keyboard's own edit is looked at again once the field's context has caught up (`clearRecheck`).
    @ObservationIgnored private var clearWatch = ClearWatch()
    @ObservationIgnored private var clearRecheck: Task<Void, Never>?
    /// Types the host's text into the field a few characters at a time; `ticker` drives it while it has text left.
    @ObservationIgnored private var reveal = TypewriterReveal()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var isTornDown = false
    private var forcedOpenAppUntil: Date?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var reapply: Task<Void, Never>?
    @ObservationIgnored private var hintTimeout: Task<Void, Never>?

    init(
        document: any TextDocument, link: LinkClient, hasFullAccess: @escaping @MainActor () -> Bool,
        preferences: @escaping () -> KeyboardPreferences = { .load() }
    ) {
        self.document = document
        self.link = link
        self.hasFullAccess = hasFullAccess
        self.preferences = preferences
        refreshPreferences()
        cursor = link.readApplied()
        host = link.readHost()
        link.observeHost { [weak self] in self?.hostDidChange() }
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
        let changed = expansion.stripEnabled != current.strip
        expansion.setStripEnabled(current.strip)
        guard changed else { return }
        stripHeight = current.stripHeight
        onLayoutChange?("setting")
    }

    /// The chevron: strip to full keyboard and back.
    func toggleExpansion() {
        guard expansion.control != nil else { return }
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
        hint ?? meetingNotice ?? dictationStatus
    }

    /// A dictation or a Refine is running: the word row is taken over and ↶ ↷ are dimmed.
    var runActive: Bool {
        if isRefining { return true }
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return false }
        return host.phase != .idle
    }

    /// Tells the word row what has taken it over (status or run), so it pauses and takes up again.
    private func syncRowTakeover() {
        wordRow.setTakeover(status: statusText, running: runActive)
    }

    /// The harness's fixed words (`LegatoHarnessSuggestions`): shown whatever is typed.
    func pinSuggestions(_ words: [String]) { wordRow.pin(words) }

    /// A slot of the word row was tapped (`rank` 0 is the best suggestion).
    func suggestionTapped(rank: Int) { wordRow.tapped(rank: rank) }

    /// While the app records a meeting dictation is blocked, and the keyboard says why instead of offering to
    /// dictate. Believed only while the app keeps beating: an app that died mid-meeting leaves the flag behind.
    var meetingNotice: String? { host?.meetingNotice(now: Date()) }

    // MARK: Visibility

    /// The keyboard came on screen: beat presence once a second, and catch up with a run in progress.
    func appeared() {
        guard !isTornDown else { return }
        isVisible = true
        refreshPreferences()
        refreshTraits()
        typing.appeared()
        wordRow.appeared()
        link.writePresence(visible: true, notify: true)
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
        // Text still to be revealed goes in now; with no field left to type into this does nothing, and the
        // rest is typed from the cursor when the keyboard (or the run's final state) is seen again.
        if reveal.needsTicks { applyHost(flush: true) }
        stopTicker()
        isVisible = false
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
        link.writePresence(visible: true, notify: false)
        reloadHost()
    }

    /// The field, its traits or the cursor changed (a new field, another return key, a tap in the text): the
    /// extension's `textDidChange` and `selectionDidChange` both come here.
    func documentDidChange() {
        refreshTraits()
        typing.documentChanged()
        if let versions, versions.documentID != document.documentID { self.versions = nil }
        if checkForClear() == .sent { applyHost() }
        trackContext()
    }

    /// A new field starts over (no history, no row); a cursor move or text change the keyboard didn't make
    /// closes the typing group and what was typed so far is learned, and the word row looks at the word there.
    private func trackContext() {
        let id = document.documentID
        if id != lastDocumentID {
            lastDocumentID = id
            history.clear()
            keptVersions = nil
            syncHistory()
            wordRow.fieldChanged()
        }
        if wordRow.contextChanged() {
            history.cursorMoved()
            wordRow.interruptTyping()
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
            state: host, cursor: cursor, documentID: document.documentID, contextBefore: document.contextBefore,
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
    private func takeClear(_ sent: AppliedCursor?) -> ClearCheck {
        cancelClearRecheck()
        if versions?.documentID == document.documentID { versions = nil }
        history.clear()
        keptVersions = nil
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
            state: host, cursor: cursor, documentID: document.documentID, contextBefore: document.contextBefore,
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
    /// The text goes in through `TypewriterReveal`: a host update only moves the target, the ticker (and
    /// `elapsedMs`, the time since its last tick) reveals it. `flush` (and Reduce Motion) types it all now.
    private func applyHost(elapsedMs: Double = 0, flush: Bool = false) {
        guard !isTornDown else { return }
        let decision = HostApplyDecision.decide(
            host: host, cursor: cursor, visible: isVisible, documentID: document.documentID, now: Date())
        guard case .apply = decision, let host, checkForClear() != .held else {
            stopTicker()
            #if DEBUG
            if case .skip(let reason) = decision, host?.insertAt != nil {
                WakeProbeLog.log("skip", "run=\(host?.runID?.prefix(8) ?? "-") reason=\(reason.rawValue)")
            }
            #endif
            return
        }
        let before = cursor
        let plan = reveal.plan(
            state: host, cursor: cursor, contextBefore: document.contextBefore, documentID: document.documentID,
            animated: !flush && !UIAccessibility.isReduceMotionEnabled, elapsedMs: elapsedMs)
        perform(plan.ops)
        startTickerIfNeeded()
        if let updated = plan.cursor, updated != before {
            cursor = updated
            // Tick writes keep the cursor exact (a restarted keyboard continues from it) but only the last one wakes the app.
            link.writeApplied(updated, notify: elapsedMs == 0 || updated.finalApplied)
            if updated.finalApplied || (elapsedMs == 0 && !plan.ops.isEmpty) {
                trace?("apply final=\(updated.finalApplied ? 1 : 0) replaced=\(updated.finalReplaced.map { $0 ? "1" : "0" } ?? "-")")
            }
            #if DEBUG
            let firstText = before?.runID != updated.runID || (before?.committedCount == 0 && before?.volatile.isEmpty == true)
            if host.insertAt != nil, !plan.ops.isEmpty, updated.finalApplied || firstText {
                WakeProbeLog.log("insert", "run=\(host.runID?.prefix(8) ?? "-") ops=\(plan.ops.count) final=\(updated.finalApplied ? 1 : 0)")
            }
            #endif
        }
        updateVersions(host)
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

    // MARK: Typewriter

    /// How often the reveal ticks. Every insert is a cross-process call to the host app, so this stays well
    /// under the display rate; a tick reveals as many characters as the time since the last one calls for.
    private static let tickInterval = Duration.milliseconds(33)

    private func startTickerIfNeeded() {
        guard reveal.needsTicks, !isTornDown, isVisible else { return stopTicker() }
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
                applyHost(elapsedMs: Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// The host's text going into the field (typewriter ticks, live re-cleans, version swaps). Never recorded in
    /// the history; whoever swaps a version records that itself.
    private func perform(_ ops: [ProxyOp]) {
        if !ops.isEmpty {
            clearWatch.ownEdit(at: Date())
            history.cursorMoved()
            wordRow.interruptTyping() // what was typed so far is learned; the host's text is not typing
        }
        for op in ops {
            switch op {
            case .deleteBackward(let count): for _ in 0..<count { document.deleteBackward() }
            case .insert(let text): document.insert(text)
            }
        }
        if !ops.isEmpty { typing.hostEdited() }
    }

    // MARK: Typing

    /// A Return holds no clear back (`ClearWatch.returnTyped`): in a chat app it sends and empties the field.
    /// `contextBefore`: the text before the cursor as the typing model tracks it (the field's own report lags).
    func type(_ text: String, contextBefore: String? = nil) {
        versions = nil // the user moved on from the dictation
        resolveHeldClear()
        beforeUserEdit()
        let before = contextBefore ?? document.contextBefore
        let selected = document.selectedText
        document.insert(text)
        if text == "\n" { clearWatch.returnTyped(at: Date()) } else { clearWatch.ownEdit(at: Date()) }
        if let selected, !selected.isEmpty {
            history.record(removed: selected, inserted: text, at: Date()) // the key replaced the selection
            wordRow.interruptTyping()
        } else {
            history.typed(text, at: Date())
            wordRow.typed(text)
        }
        syncHistory()
        wordRow.keystroke(contextBefore: before + text)
        afterUserEdit()
    }

    func deleteBackward(contextBefore: String? = nil) {
        versions = nil
        resolveHeldClear()
        clearWatch.ownEdit(at: Date())
        beforeUserEdit()
        let before = contextBefore ?? document.contextBefore
        let selected = document.selectedText
        document.deleteBackward()
        if let selected, !selected.isEmpty {
            history.record(removed: selected, inserted: "", at: Date())
            wordRow.interruptTyping()
        } else if let last = before.last {
            history.deleted(String(last), at: Date())
            wordRow.deletedTyped()
        }
        syncHistory()
        wordRow.keystroke(contextBefore: String(before.dropLast()))
        afterUserEdit()
    }

    /// One edit of the word row (a completion or a swap), or of undo and redo: move to the end of the span,
    /// delete backwards, insert. `removed` is the text the edit takes out, for the history; `asTyping` marks a
    /// completion, which the row follows up with predictions and which counts as typed text. `record: false`
    /// is for undo and redo, which move the history themselves.
    func applyEdit(_ edit: WordEdit, removed: String, asTyping: Bool, record: Bool = true) {
        resolveHeldClear()
        beforeUserEdit()
        let before = typing.contextBefore
        let moved = before + String(document.contextAfter.prefix(edit.forward))
        let expected = String(moved.dropLast(edit.deleteCount)) + edit.insert
        versions = nil
        wordRow.interruptTyping()
        if asTyping {
            for _ in 0..<edit.deleteCount { wordRow.deletedTyped() }
            wordRow.typed(edit.insert)
        } else {
            wordRow.willApplyOwnEdit(expectedContextBefore: expected)
        }
        clearWatch.ownEdit(at: Date())
        if edit.forward != 0 { document.adjustTextPosition(byCharacterOffset: edit.forward) }
        for _ in 0..<edit.deleteCount { document.deleteBackward() }
        if !edit.insert.isEmpty { document.insert(edit.insert) }
        if record { history.record(removed: removed, inserted: edit.insert, at: Date()) }
        syncHistory()
        typing.ownEdit(contextBefore: expected)
        // A completion, undo or redo goes on with what fits the new cursor position; a swap empties the row.
        if asTyping || !record { wordRow.keystroke(contextBefore: expected) }
        afterUserEdit()
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
        prepareHistoryStep()
        guard let step = history.undo(contextBefore: typing.contextBefore) else { return historyRefused() }
        syncHistory()
        run(step)
    }

    func redo() {
        guard canRedo else { return }
        prepareHistoryStep()
        guard let step = history.redo(contextBefore: typing.contextBefore) else { return historyRefused() }
        syncHistory()
        run(step)
    }

    private func prepareHistoryStep() {
        resolveHeldClear()
        if reveal.needsTicks { applyHost(flush: true) }
        wordRow.interruptTyping()
    }

    /// The field changed behind the keyboard's back: the guard cleared the history.
    private func historyRefused() {
        syncHistory()
        show("The text changed, so there is nothing to undo.")
    }

    private func run(_ step: EditHistory.Step) {
        switch step {
        case .edit(let edit):
            applyEdit(edit, removed: "", asTyping: false, record: false)
        case .version(let index):
            if !showVersion(at: index, record: false) {
                history.clear()
                syncHistory()
            }
        }
    }

    /// The user types into a run's text: the tentative text comes out first so the key lands after the
    /// committed text; `applyHost` puts it back after the key.
    private func beforeUserEdit() {
        // Committed text still to be revealed goes in first, so the key does not land in the middle of it.
        if reveal.needsTicks { applyHost(flush: true) }
        guard let current = cursor, let documentID = document.documentID, current.documentID == documentID,
              let host, host.runID == current.runID, host.phase != .idle
        else { return }
        let plan = ProxyEditPlanner.prepareForTyping(cursor: current, contextBefore: document.contextBefore)
        perform(plan.ops)
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

    /// Whether the app is capturing right now (a fresh beat and a run starting or listening).
    var isCapturing: Bool {
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return false }
        return host.phase == .starting || host.phase == .listening
    }

    /// What tapping the mic key does now.
    var micMode: MicKeyMode {
        if let until = forcedOpenAppUntil, until > now, hasFullAccess() { return .openApp }
        return MicKeyMode.resolve(host: host, now: now, fullAccess: hasFullAccess())
    }

    /// What the open-app key asks of the app: to arm the microphone, not to dictate (the app is in front
    /// of the host app's field then). The dictation starts with the next tap, back in the host app.
    var openAppCommand: RequestCommand { MicKeyMode.openApp.request ?? .arm }

    /// The mic key was tapped. In `.openApp` mode the key is a `Link` that opens the app by itself; this
    /// sends the same request over the link, for an app that is already running.
    func micTapped() {
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
                self?.openAppRequestID = UUID().uuidString
            }
        case .remote(let action):
            trace?("mic mode=remote-\(action == .start ? "start" : "stop")")
            Task { await sendRemote(action) }
        }
    }

    /// Asks the running app; without an ack in time (or an ack of `hop`) the key becomes an open-app
    /// key for a few seconds, because opening the app takes a real tap on the Link.
    private func sendRemote(_ action: RemoteAction) async {
        let id = UUID().uuidString
        link.send(action == .start ? .start : .stop, id: id)
        let result = await link.awaitAck(id: id, timeout: LinkChannel.ackTimeout)
        trace?("ack result=\(result?.rawValue ?? "timeout")")
        guard result != .accepted else {
            // "Accepted" is the app taking the request on; a start can still fail afterwards (the system
            // refused the microphone), and then the app answers the same request again with `hop`.
            if action == .start { await watchForFailedStart(id: id) }
            return
        }
        needsAppOpened()
    }

    /// Watches a start the app accepted until the run is listening, or the app says it could not start.
    private func watchForFailedStart(id: String) async {
        let deadline = ContinuousClock.now + .seconds(Self.startWatchSeconds)
        while ContinuousClock.now < deadline, isVisible {
            if let ack = link.readAck(), ack.id == id, ack.result == .hop {
                trace?("ack result=hop-after-accept")
                needsAppOpened()
                return
            }
            reloadHost()
            if let host, host.isLive(now: now), host.phase == .listening { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// How long a remote start is watched for failing after it was accepted.
    private static let startWatchSeconds = 8.0

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
        wordRow.willApplyOwnEdit(
            expectedContextBefore: String(before.dropLast(current.shown.count)) + current.texts[index] + current.trailing)
        perform(ops)
        current.show(index)
        versions = current // undoing the typing that followed the dictation makes Refine possible again
        keptVersions = current
        if record, from != index {
            history.recordVersion(from: from, to: index, at: Date())
            syncHistory()
        }
        trace?("version index=\(index) of=\(current.texts.count)")
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
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return nil }
        switch host.phase {
        case .starting, .listening:
            let live = host.committed + host.volatile
            guard host.delivery == .hold, !live.trimmingCharacters(in: .whitespaces).isEmpty else { return "Listening…" }
            return live.count > 90 ? "…" + live.suffix(90) : live
        case .finishing:
            return host.delivery == nil ? nil : "Cleaning up…"
        case .idle:
            return nil
        }
    }

    /// The emoji key: the emoji panel lands later; for now it says so.
    func emojiTapped() {
        show("Emoji is coming soon.")
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
