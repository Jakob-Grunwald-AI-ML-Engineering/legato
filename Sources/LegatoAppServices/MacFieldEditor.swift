#if os(macOS)
import Foundation
import Observation
import LegatoAgent
import LegatoCore
import LegatoKeyboardCore
import LegatoMac

/// A panel-mode dictation: the notch panel shows the take's words while it runs and is cleaned, and the finished
/// text is typed into the app once at the end (`MacFieldEditor.insert`).
@MainActor @Observable public final class DictationPanel {
    /// This session dictates through the panel (from its start until the next one begins).
    public fileprivate(set) var active = false
    public fileprivate(set) var take = PanelTake()
    /// The finished text is being typed into the app.
    public fileprivate(set) var inserting = false
    public init() {}
}

/// Whether Legato's own last change in the bound field can be undone or redone (the pill's controls enable by it).
@MainActor @Observable public final class FieldHistory {
    public fileprivate(set) var canUndo = false
    public fileprivate(set) var canRedo = false
    public init() {}
}

/// The Mac's dictation and Magic side of the focused field. It binds the field when a session starts and hands every
/// change to the field's one queue (`MacFieldQueue`): live words and their revisions, cleanup, typed lines, Magic and
/// its undo, and the panel's final typed insert. It writes nothing itself; Magic's reads come from here.
@MainActor public final class MacFieldEditor: InstructionField {
    /// How a panel-mode take reached the app.
    public enum InsertOutcome: Sendable, Equatable {
        case typed
        /// Typing stopped part-way; the rest is on the clipboard.
        case interrupted(message: String)
        /// A guard failed before typing; all of it is on the clipboard.
        case copied(message: String)
    }
    private let capture: @MainActor () -> FocusedField
    /// Typewriter pacing of the queue (false with Reduce Motion).
    public var typewriter: @MainActor () -> Bool = { true }
    public var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    public var report: @MainActor (String) -> Void = { _ in }
    public var recover: @MainActor (String) -> Void = { _ in }
    /// Which fields dictate through the panel (`PanelDictationPolicy`).
    public var panelMode: @MainActor () -> PanelDictationSetting.Mode = { PanelDictationSetting.defaultMode }
    /// Types a panel-mode take into the app the session started in, under the host's guards (synthetic keys).
    public var insert: (@MainActor (String) async -> InsertOutcome)?
    /// Where the queue's journal goes (debug and internal builds).
    public var journal: (@MainActor (MacEditJournal.Entry) -> Void)?
    public let panel = DictationPanel()
    public let history = FieldHistory()
    /// The field's queue; a new one per bound field.
    public private(set) var queue = MacFieldQueue(target: nil)
    /// The session's last words were delivered: finished panel text is typed as soon as it is final.
    private var sessionEnded = false
    /// Real input since the start: the panel's text is copied, never typed.
    private var panelOwned = true
    /// The focused element reads as text but takes no writes and no keys (a page, not a field): the panel's text is
    /// copied, never typed (a typed letter could be the site's shortcut).
    private var panelCopiesOnly = false
    /// The bound field stopped reading part-way through the take: the rest of it went on in the panel (`fallBack`), and
    /// its text is typed at the end with synthetic keys, not through the queue.
    private var fieldUnreadable = false
    /// Runs handed to the panel after part of them was typed live: what each newer version adds past the typed part.
    private var continuations: [String: PanelContinuation] = [:]
    /// A handed-over run typed something: the panel's text continues it and brings its own spacing.
    private var continuesTyped = false
    private var target: (any TextTarget)?
    /// The bound field is a password field: its takes are not kept in History (the host gates the pipeline's writes).
    public private(set) var passwordField = false
    private var documentID = UUID().uuidString
    private var activeInstructionID: String?
    private var streamedRunID: String?
    /// Runs this editor saw; a rebind retires them, so a late cleanup never follows into another field or session.
    private var seenRunIDs: Set<String> = []
    private var retiredRunIDs: Set<String> = []
    private var readSelection: UTF16Range?
    private var instructionCursor: UTF16Range?
    private var readText: String?
    private var readRange: UTF16Range?
    public init(capture: @escaping @MainActor () -> FocusedField) { self.capture = capture }

    public func begin() {
        panel.active = false; panel.take = PanelTake(); sessionEnded = false; panelOwned = true
        continuations = [:]; continuesTyped = false
        bind()
    }

    /// Binds the focused field to a fresh queue. The panel session (its words and whether it runs) is left to the caller.
    private func bind() {
        queue.reset(.cancelled)
        retiredRunIDs.formUnion(seenRunIDs); seenRunIDs = []
        target = nil; streamedRunID = nil; activeInstructionID = nil; fieldUnreadable = false
        readSelection = nil; readText = nil; readRange = nil; instructionCursor = nil
        documentID = UUID().uuidString
        let field: DictationFieldKind
        switch capture() {
        case .target(let value):
            target = value
            field = value.editsInPlace || value.typesKeys ? .liveEditable : .readOnly
        case .password: field = .password
        case .none: field = .unreadable
        }
        passwordField = field == .password
        panelCopiesOnly = field == .readOnly
        queue = MacFieldQueue(target: target, documentID: documentID)
        queue.paced = { [weak self] in self?.typewriter() ?? true }
        queue.sleep = { [weak self] in await self?.sleep($0) }
        queue.journal = journal
        queue.onDrop = { [weak self] drop in self?.dropped(drop) }
        queue.onUnreadable = { [weak self] handovers in self?.fallBack(handovers) }
        queue.onHistoryChange = { [weak self] in self?.syncHistory() }
        syncHistory()
        journal?(.init(kind: .field, field: documentID))
        if PanelDictationPolicy.usesPanel(panelMode(), field: field) { panel.active = true }
    }

    private func syncHistory() {
        if history.canUndo != queue.canUndo { history.canUndo = queue.canUndo }
        if history.canRedo != queue.canRedo { history.canRedo = queue.canRedo }
    }

    /// Takes Legato's last change in the field back (a take, a cleanup or a Magic edit), or puts it back, through the queue.
    public func undoLast() async { _ = await queue.undo() }
    public func redoLast() async { _ = await queue.redo() }

    /// The field stopped reading while it had focus: the take goes on in the panel for the rest of it. What was typed
    /// live stays; the panel shows the rest as it grows and is cleaned, and types it once at the end. Nothing is dropped.
    private func fallBack(_ handovers: [MacFieldQueue.Handover]) {
        fieldUnreadable = true
        if !panel.active { panel.active = true; panel.take = PanelTake() }
        for handover in handovers {
            var continuation = PanelContinuation(text: handover.text, typed: handover.typed)
            let rest = continuation.rest
            continuations[handover.runID] = continuation
            if handover.typed > 0 { continuesTyped = true }
            panelVersions[handover.runID] = max(panelVersions[handover.runID] ?? -1, handover.version)
            panel.take.live(id: handover.runID, text: rest, complete: handover.complete)
        }
        if sessionEnded { scheduleInsert() }
    }

    /// Work the queue could not place: the take or result is in History; the text goes to the clipboard too.
    private func dropped(_ drop: MacFieldQueue.Drop) {
        guard !drop.text.isEmpty, drop.reason != .cancelled else { return }
        recover(drop.text)
        report(drop.runID == nil
               ? "Magic's result couldn't be placed: the text changed. It's in History."
               : "Some dictated words couldn't be placed where the text changed. They're in History and on the clipboard.")
    }

    /// The user typed or clicked: the queue takes their caret and text from the next read and replans around them.
    public func relinquish() { panelOwned = false; queue.userActed() }
    public func cancel(instructionID: String) {
        guard activeInstructionID == instructionID else { return }
        activeInstructionID = nil
        readSelection = nil; readText = nil; readRange = nil
    }
    /// Another app came forward: the queue waits for the field (and drops its work if it does not come back).
    public func focusChanged() { if target?.isFocused() == false { panelOwned = false } }

    public func beginInstruction() {
        // A Magic start binds the field in front now when it is not the bound one. A panel session keeps its words.
        // The same editor shown as a fresh element (a web page re-rendered it) stays bound, with its queue.
        if !queue.ensureFocused() {
            if panel.active { bind() } else { begin() }
        }
        // An explicit new Magic start owns a fresh result namespace, in the same field too.
        documentID = UUID().uuidString
        activeInstructionID = nil
        instructionCursor = try? target?.selectedRange()
        readSelection = nil; readText = nil; readRange = nil
    }

    // MARK: Dictation

    /// Every live snapshot goes to the queue (or the panel); the queue coalesces to the newest per run.
    public func enqueueLive(_ snapshot: LiveDictationSnapshot?) {
        guard let snapshot else { return }
        if panel.active { showInPanel(snapshot); return }
        guard !retiredRunIDs.contains(snapshot.runID) else { return }
        seenRunIDs.insert(snapshot.runID); streamedRunID = snapshot.runID
        guard target != nil else {
            if snapshot.complete { copyUnwritable(Self.body(of: snapshot)) }
            return
        }
        queue.live(runID: snapshot.runID, version: snapshot.version, text: Self.body(of: snapshot), complete: snapshot.complete)
    }
    public func applyLive(_ snapshot: LiveDictationSnapshot?) async {
        enqueueLive(snapshot)
        await queue.whenIdle()
    }

    /// No field outside panel mode (not reached by a fresh bind: every unreadable field uses the panel): finished text
    /// only reaches the clipboard.
    private func copyUnwritable(_ text: String) {
        guard !text.isEmpty else { return }
        recover(text); report("Dictation copied. The field is unavailable or changed; paste with ⌘V.")
    }

    private static func body(of snapshot: LiveDictationSnapshot) -> String {
        snapshot.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func deliver(_ text: String) {
        enqueueLive(.init(runID: UUID().uuidString, version: 1, segments: [.init(id: 0, text: text, final: true)], complete: true))
    }

    /// A take whose cleanup streams: each state of it goes to the queue as the run's newest text.
    public func stream(_ poll: @MainActor () -> DictationStreamState?) async -> Bool {
        if panel.active { return await streamInPanel(poll) }
        let id = UUID().uuidString
        streamedRunID = id
        seenRunIDs.insert(id)
        var version = 0
        while let state = poll() {
            version += 1
            // The field stopped reading part-way (`fallBack`): the rest of the stream goes on in the panel.
            if continuations[id] != nil {
                panel.take.stream(id: id, text: panelText(id, state.text), final: state.isFinal || state.retracted, retracted: state.retracted)
                if state.isFinal || state.retracted { if sessionEnded { scheduleInsert() }; return false }
                if state.stalled { return true }
                try? await Task.sleep(for: .milliseconds(30))
                continue
            }
            if state.retracted { _ = retractStreamed(); return false }
            if target == nil { if state.isFinal { copyUnwritable(state.text) }; if state.isFinal || state.stalled { return state.stalled } }
            else { queue.live(runID: id, version: version, text: state.text, complete: state.isFinal) }
            if state.isFinal { return false }
            if state.stalled { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    /// Retry / Insert as-is take the last take back out (the queue restores what it replaced).
    @discardableResult public func retractStreamed() -> Bool {
        if panel.active { panel.take.dropGrowing(); return true }
        guard let id = streamedRunID else { return true }
        streamedRunID = nil
        queue.retract(runID: id)
        return true
    }

    /// The session's last words were delivered: the queue finishes its work (paced). A panel session types its
    /// finished text now; a take still held (failed cleanup) follows once the user chose Retry or Insert as-is.
    public func finish() async {
        await queue.whenIdle()
        guard panel.active else { return }
        sessionEnded = true
        scheduleInsert()
        await insertTask?.value
    }

    public func contextBeforeCursor() -> String {
        guard let target, queue.ensureFocused(), let cursor = try? target.selectedRange() else { return "" }
        let length = min(cursor.location, 600)
        return (try? target.text(in: .init(location: cursor.location - length, length: length))) ?? ""
    }
    public func publish(_ strip: InstructionStrip) {}

    // MARK: Panel

    private var insertTask: Task<Void, Never>?
    private var panelVersions: [String: Int] = [:]

    private func showInPanel(_ snapshot: LiveDictationSnapshot) {
        guard snapshot.version > (panelVersions[snapshot.runID] ?? -1) else { return }
        panelVersions[snapshot.runID] = snapshot.version
        panel.take.live(id: snapshot.runID, text: panelText(snapshot.runID, Self.body(of: snapshot)), complete: snapshot.complete)
        if sessionEnded { scheduleInsert() }
    }

    /// A run's text as the panel shows it: past what was typed live when the run went on in the panel part-way.
    private func panelText(_ runID: String, _ text: String) -> String {
        guard var continuation = continuations[runID] else { return text }
        let rest = continuation.rest(of: text)
        continuations[runID] = continuation
        return rest
    }

    /// Follows a take whose cleanup streams: the cleaned words replace the raw ones in the panel as they come.
    private func streamInPanel(_ poll: @MainActor () -> DictationStreamState?) async -> Bool {
        let id = UUID().uuidString
        while let state = poll() {
            panel.take.stream(id: id, text: state.text, final: state.isFinal || state.retracted, retracted: state.retracted)
            if state.isFinal || state.retracted { break }
            if state.stalled { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        if sessionEnded { scheduleInsert() }
        return false
    }

    /// Types what is finished, in order, after any insert still running. A growing piece (a stalled take waiting for
    /// Retry or Insert as-is) holds back what follows it.
    private func scheduleInsert() {
        let previous = insertTask
        insertTask = Task { [weak self] in
            await previous?.value
            await self?.insertFinished()
        }
    }

    private func insertFinished() async {
        guard panel.active else { return }
        let first = panel.take.isFirstHandOver
        var text = panel.take.takeFinished()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A field the queue edits (Accessibility, or verified keys): the finished text goes in once through the queue,
        // one insert at the user's caret, typed at the fast end of the pace. Input meanwhile only moves where it goes.
        if let target, !panelCopiesOnly, !fieldUnreadable, target.editsInPlace || target.typesKeys {
            panel.inserting = true
            defer { panel.inserting = false }
            let id = UUID().uuidString
            seenRunIDs.insert(id)
            queue.live(runID: id, version: 1, text: text, fast: true)
            await queue.whenIdle()
            return
        }
        // A readable field tells which space the first words need after its own text.
        if first, !continuesTyped, let target, target.isFocused(), let caret = try? target.selectedRange(), caret.location > 0,
           let previous = (try? target.text(in: .init(location: caret.location - 1, length: 1)))?.last {
            text = PanelTake.separator(before: text, after: previous) + text
        }
        guard panelOwned, !panelCopiesOnly, let insert else {
            recover(text.trimmingCharacters(in: .whitespaces))
            report(panelCopiesOnly ? "Dictation copied: this isn't a text field. Paste with ⌘V."
                                   : "Dictation copied: the field or app changed. Paste with ⌘V.")
            return
        }
        panel.inserting = true
        defer { panel.inserting = false }
        // The panel's one op: a typed insert, in the field's queue like every other change.
        switch await queue.exclusive(label: "panel", text: text, { await insert(text) }) {
        case .typed: break
        case .interrupted(let message), .copied(let message): report(message)
        }
    }

    // MARK: Magic

    public func read(_ kind: FieldReadRequest.Kind, instructionID: String, reading: @escaping @MainActor () -> Void) async throws -> FieldReadReply {
        guard !passwordField else { throw InstructionFailure.unreadable("Magic doesn't edit password fields.") }
        guard let target else { throw InstructionFailure.unreadable("Magic can't read this field. Nothing was edited.") }
        // Dictation still on its way lands first, all at once, so Magic reads the finished text.
        await queue.flush()
        guard queue.ensureFocused(), let selection = try? target.selectedRange() else {
            throw InstructionFailure.unreadable("The field changed. Nothing was edited.")
        }
        let length = try target.textLength()
        guard selection.location >= 0, selection.end <= length else { throw InstructionFailure.unreadable("The field changed. Nothing was edited.") }
        let cap = FieldReader.defaultCap
        guard selection.length <= cap else { throw InstructionFailure.unreadable("The selection is too long. Select a smaller passage.") }
        let room = cap - selection.length
        let afterLength = min(length - selection.end, room / 3)
        let beforeLength = min(selection.location, room - afterLength)
        let lower = selection.location - beforeLength
        let upper = min(length, selection.end + room - beforeLength)
        let range = UTF16Range(location: lower, length: upper - lower)
        let snapshot = try target.text(in: range)
        guard snapshot.utf16.count == range.length, try target.selectedRange() == selection else {
            throw InstructionFailure.unreadable("The text changed while Magic was reading it.")
        }
        // Derive all model context from one observed snapshot; separate AX reads could mix revisions.
        let captured = snapshot as NSString
        var above = captured.substring(with: NSRange(location: 0, length: selection.location - lower))
        var below = captured.substring(with: NSRange(location: selection.end - lower, length: upper - selection.end))
        let selected = selection.length > 0 ? captured.substring(with: NSRange(location: selection.location - lower, length: selection.length)) : nil
        var aboveStop: FieldStop = lower == 0 ? .start : .cap
        var belowStop: FieldStop = upper == length ? .start : .cap
        if let stop = FieldReader.structuralStop(in: above, atFieldStart: lower == 0) {
            above = String(above[stop.index...]); aboveStop = stop.kind
        }
        if let stop = FieldReader.structuralStopBelow(in: below) {
            below = String(below[..<stop.index]); belowStop = stop.kind
        }
        activeInstructionID = instructionID
        readSelection = selection; readText = snapshot; readRange = range; instructionCursor = selection
        var sessionLength = 0
        if let span = queue.lastRegionAtCaret, span.range.end == selection.location, selection.length == 0 {
            sessionLength = min(span.text.count, above.count)
        }
        return FieldReadReply(id: instructionID, state: .done, above: above, below: below, selection: selected,
                              sessionLength: sessionLength, stop: aboveStop,
                              stopBelow: belowStop, moreAbove: aboveStop == .cap,
                              moreBelow: belowStop == .cap, documentID: documentID, revision: nil)
    }

    /// Magic's result (or its undo) goes to the queue as one edit of the text it read; the user's typing or clicks
    /// meanwhile rebase it, and only a scope the user changed is refused.
    public func apply(_ edit: ScopedEdit) async -> ScopedEditAck? {
        func refused(_ reason: String) -> ScopedEditAck { .init(id: edit.id, applied: false, reason: reason) }
        guard edit.documentID == documentID, let target else { return refused("The focused field changed. Nothing was edited.") }
        guard let anchor = readSelection ?? instructionCursor else { return refused("The field changed. Nothing was edited.") }
        let range: UTF16Range
        if let selected = edit.selected {
            guard anchor.length == selected.utf16.count else { return refused("The selection changed.") }
            range = anchor
        } else {
            guard anchor.location >= edit.before.utf16.count else { return refused("The cursor moved.") }
            range = .init(location: anchor.location - edit.before.utf16.count, length: edit.scopeText.utf16.count)
        }
        // Context from the text Magic read (or the field as it is, for an undo): it places the edit uniquely.
        let source: (text: NSString, base: Int)? = readText.flatMap { text in readRange.map { (text as NSString, $0.location) } }
        func context(_ location: Int, _ length: Int) -> String {
            if let source, location - source.base >= 0, location - source.base + length <= source.text.length {
                return source.text.substring(with: NSRange(location: location - source.base, length: length))
            }
            return (try? target.text(in: .init(location: max(0, location), length: max(0, length)))) ?? ""
        }
        let beforeLength = min(MacFieldQueue.contextChars, range.location)
        let before = context(range.location - beforeLength, beforeLength)
        let after = context(range.end, MacFieldQueue.contextChars)
        readSelection = nil; readText = nil; readRange = nil
        let result = await queue.edit(.init(id: edit.id, range: range, scope: edit.scopeText, before: before, after: after,
                                            target: edit.target, caretAfter: true))
        switch result {
        case .applied(let landed):
            instructionCursor = UTF16Range(location: landed.end, length: 0)
            return .init(id: edit.id, applied: true, cursor: edit.target.utf16.count, revision: nil)
        case .dropped(.userChanged):
            return refused("The text changed. Nothing more was edited.")
        case .dropped(.failed):
            return .init(id: edit.id, applied: false,
                         reason: "The app did not confirm the edit. The original and suggestion are saved; check the field before retrying.",
                         stopped: true)
        case .dropped:
            return refused("The field changed. Nothing was edited.")
        }
    }
}
#endif
