import Foundation
import LegatoKeyboardCore

/// The one writer of a bound text field on the Mac. Every change Legato makes to the field goes through it: live
/// dictation and its revisions, cleanup, typed lines, Magic and its undo, and (in panel mode) the final typed insert.
///
/// - One op in flight: each op is planned just before it is sent, against the field as last read, then read back
///   (text and selection) before the next. With Accessibility an op selects its spot, replaces, and reads back.
/// - Minimal diff: a change replaces only the differing characters (`ShadowEditPlanner.changes`). A change away from
///   the user's caret is a jump unit: the op selects the spot, edits those characters, and the caret goes back to
///   where the user expects it (after the open dictation region, or where the user put it).
/// - Typewriter: one grapheme per op at the typewriter pace; `paced` false (Reduce Motion) or `flush()` sends each
///   change whole.
/// - Keystrokes: a field that reads but ignores Accessibility writes (`TextTarget.typesKeys`, Chromium web content)
///   is edited with synthetic keys, one key in flight, each confirmed by reading the field back: Backspace to delete,
///   one grapheme per Unicode key to type. An edit key counts by the field's value (the expected text at its place);
///   a caret that lags behind a landed key is waited for, never answered with the key again. `KeystrokePlanner`
///   chooses the keys (whole-word and merged spans, minimal or block per span, about `KeystrokePlanner.budgetMs` per
///   change, paced by the backlog). A key whose guard fails is not sent; the next step reads again and replans.
/// - Jumps: the caret goes straight to a change and back. Each jump is one verified step: an Accessibility caret set
///   where the field honours it (proven once by one arrow), else Option word hops, Command line or document hops
///   where they provably aim at the target, and runs of plain arrows for the rest. A jump that lands elsewhere is
///   corrected from where the field reports the caret, within `jumpRounds`; then arrows only. What works is
///   remembered per field (`CaretJumps`).
/// - Never freezes on the user: their typing and clicks are seen on the next read. Regions (the text a run or edit
///   owns) are found again at their place or uniquely elsewhere, and pending work is replanned there. A key or click
///   closes the open dictation region; later words start a new region at the user's caret, and revisions of closed
///   regions still land while their text is unchanged. Only work whose text the user changed, or that cannot be
///   placed, is dropped (`onDrop`).
/// - Focus by editor, not by element: when the bound element no longer reads as focused, the queue binds the element
///   that has focus if it is the same editor (a web page recreates elements and moves focus between nested ones as its
///   DOM changes), or any text field of the app while nothing was typed yet (`TextTarget.refocus`), and finds its work
///   there again. Otherwise it waits up to `parkLimit`, then each take drops once, whole. A field that keeps focus but
///   stops reading is not gone: after `unreadableGrace` its dictation goes on in the panel (`onUnreadable`).
@MainActor
public final class MacFieldQueue {
    public enum Reason: String, Sendable, Equatable { case userChanged, cannotPlace, focusLost, cancelled, failed }
    public struct Drop: Sendable, Equatable {
        public var id: String
        public var runID: String?
        public var reason: Reason
        /// The text that did not reach the field (the whole desired text of the work).
        public var text: String
        /// Characters already represented in the field, including an unconfirmed key that may have landed.
        public var typed: Int = 0
    }
    /// A change of read text: `scope`, read at `range` between `before` and `after`, becomes `target`.
    public struct Edit: Sendable, Equatable {
        public var id: String
        public var range: UTF16Range
        public var scope: String
        public var before: String
        public var after: String
        public var target: String
        /// When it lands, the caret goes after the result (Magic) rather than back to where the user had it.
        public var caretAfter: Bool
        public init(id: String = UUID().uuidString, range: UTF16Range, scope: String, before: String = "", after: String = "",
                    target: String, caretAfter: Bool = false) {
            self.id = id; self.range = range; self.scope = scope; self.before = before; self.after = after; self.target = target
            self.caretAfter = caretAfter
        }
    }
    public enum EditResult: Sendable, Equatable {
        /// The result's range in the field.
        case applied(UTF16Range)
        case dropped(Reason)
        /// Confirmed changes were made before editing stopped; the caller must not claim nothing was edited.
        case stopped(Reason)
    }
    /// A run handed to the panel because its field stopped reading (`onUnreadable`): `text` is its newest text, of which
    /// the first `typed` characters stand for what is in the field already. That text stays as it is.
    public struct Handover: Sendable, Equatable {
        public var runID: String
        public var version: Int
        public var text: String
        public var typed: Int
        public var complete: Bool
        /// An interrupted internal revision cannot safely be appended after the field's existing tail. Keep its
        /// whole suggestion in the panel for review, while preserving the queue's lossless handover contract.
        public var requiresReview: Bool = false
    }

    // MARK: Tunables

    /// Text found again away from its place must occur there once and be at least this long; shorter text needs its
    /// context to match too.
    public static let relocateMinimum = 4
    /// An edit's scope found away from where it was read must be at least this long when its context is gone.
    public static let relocateChars = 16
    public static let contextChars = 16
    /// How long work waits for an unfocused field before it is dropped (or, without `onUnreadable`, an unreadable one).
    public static let parkLimit = Duration.seconds(3)
    /// How long dictation waits for a focused field that does not read before it goes on in the panel (`onUnreadable`).
    public static let unreadableGrace = Duration.milliseconds(600)
    /// How long an edit waits for its text to show before it counts as unplaceable.
    public static let placeGrace = Duration.milliseconds(400)
    /// Ops of one region that failed to verify in a row before its work is dropped.
    public static let retryLimit = 4
    /// The pause between attempts while the field cannot take an op.
    public static let waitTick = Duration.milliseconds(50)
    /// Fields up to this long are read whole; longer ones around the work.
    public static let readCap = 60_000
    /// How long a key's read-back may take before the key counts as not landed (it may still land late).
    public static let keyConfirm = Duration.milliseconds(400)
    /// The pause between read-backs of a key.
    public static let keyPoll = Duration.milliseconds(4)
    /// A key that did not read back within `keyConfirm` may still land until this long after it went out: nothing is
    /// sent (and the key is not sent again) before it shows or this passes.
    public static let keyLateLimit = Duration.seconds(1)
    /// Keystroke fields: after the user's real key or click, no key goes out until their input has rested this long.
    /// A key moves the field's own caret, so a key the user types meanwhile lands wherever the queue's caret is.
    public static let keyQuiet = Duration.milliseconds(600)
    /// Typed graphemes of one change go out in runs of at most this many, each key verified by the caret alone and the run
    /// by one read of the text; `pipelineRunBehind` while typing is behind speech.
    public static let pipelineRun = 4
    public static let pipelineRunBehind = 8
    /// How long a run's key may take to show its caret before the run is verified whole (and the key is waited for).
    public static let pipelineWait = Duration.milliseconds(120)
    /// The pause at a transition between moves and edits.
    public static let keySettle = Duration.milliseconds(Int(KeystrokePlanner.settleMs))
    /// How long an edit key whose text already shows may wait for the caret before it counts as landed with a lagging
    /// caret (Chromium reports the caret of a key typed on an empty line or at a block start late).
    public static let caretWait = Duration.milliseconds(150)
    /// How long an Accessibility caret set may take to read back; one that does not is never tried again in the field.
    public static let caretSetConfirm = Duration.milliseconds(60)
    /// A caret set that did not read back may still take until this long after it.
    public static let caretSetLateLimit = Duration.milliseconds(300)
    /// A run of plain arrows is at most this long; farther moves hop first.
    public static let arrowRun = 8
    /// Jumps (caret sets and hops) toward one target before only arrows go.
    public static let jumpRounds = 4
    /// A move that lands off its prediction counts once the caret held still this long (a run of arrows shows its keys
    /// one by one; a lagging caret report catches up).
    public static let moveStable = Duration.milliseconds(40)

    // MARK: Configuration

    public let documentID: String
    public let target: (any TextTarget)?
    /// Typewriter pacing (false with Reduce Motion: every change goes whole).
    public var paced: @MainActor () -> Bool = { true }
    public var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    public var now: @MainActor () -> ContinuousClock.Instant = { .now }
    public var journal: (@MainActor (MacEditJournal.Entry) -> Void)?
    public var onDrop: (@MainActor (Drop) -> Void)?
    /// Work is fully confirmed or dropped; called before resuming idle waiters.
    public var onIdle: (@MainActor () -> Void)?
    /// The bound field still has focus but stopped reading for `unreadableGrace`: its pending dictation goes on in the
    /// panel. Each run is handed over once, never dropped; the queue leaves it (and its later versions) alone from then.
    /// Nil: such work waits and drops after `parkLimit` like work for an unfocused field.
    public var onUnreadable: (@MainActor ([Handover]) -> Void)?
    /// A failed native transport gets one reassessment for this bound field, never a cycle of retries.
    private var reassessedWriteFailure = false
    /// Counts changes the queue saw land (its own, verified, and the user's).
    public private(set) var revision = 0

    public init(target: (any TextTarget)?, documentID: String = UUID().uuidString) {
        self.target = target; self.documentID = documentID
    }

    // MARK: State

    private final class Region {
        let id: String
        let runID: String?
        var start: Int
        var current: [Character]
        var desired: [Character]
        /// Runs: the run text this region stands for, and the space put ahead of it.
        var source: [Character] = []
        var separator: [Character] = []
        /// A region after the run's first starts at the user's caret: whitespace leading its words is the separator's job.
        var trimsLead = false
        var open: Bool
        var lost = false
        var retracting = false
        var caretAfter = false
        var dropReason: Reason = .userChanged
        /// What the region replaced when it started (a run's initial selection), for a retract.
        var original: String = ""
        var before = "", after = ""
        /// `after` runs to the end of the field.
        var afterAtEnd = false
        var failures = 0
        /// An op that did not read back yet: if the field shows this next, the op landed late.
        var landing: [Character]?
        /// Keystroke fields: the planned keys toward `desired`.
        var keys: KeyUnit?
        var nativePlan: NativeEditPlan?
        var verifiedWrites = 0
        var uncertainWrite = false
        init(id: String, runID: String?, start: Int, current: [Character], desired: [Character], open: Bool) {
            self.id = id; self.runID = runID; self.start = start; self.current = current; self.desired = desired; self.open = open
        }
        var end: Int { start + String(current).utf16.count }
        var pending: Bool { !lost && current != desired }
    }
    /// A region's planned edit keys (`KeystrokePlanner.steps`), done up to `index`.
    private final class KeyUnit {
        let desired: [Character]
        let steps: [KeystrokePlanner.Step]
        var index = 0
        /// The gap between its typed graphemes that spreads the change over the time budget.
        let paceMs: Double
        init(desired: [Character], steps: [KeystrokePlanner.Step], paceMs: Double) {
            self.desired = desired; self.steps = steps; self.paceMs = paceMs
        }
        var typedLeft: Int { steps[index...].reduce(0) { if case .type = $1.key { $0 + 1 } else { $0 } } }
    }
    private enum KeyKind { case move, edit }
    private struct Run {
        var id: String
        var version = -1
        var target: [Character] = []
        var regions: [Region] = []
        /// Run text after the last region that still needs a region of its own.
        var remainder: [Character] = []
        var retracted = false
        /// The run was dropped as a whole (its field went away): its later versions are not placed and not dropped again.
        var abandoned = false
        /// The run's last words were delivered (it can be undone as a whole).
        var complete = false
        /// Typed at the fast end of the pace (a panel take's one insert at its end).
        var fast = false
        var speaking = false
        var speechTarget = FieldSpeechScheduling.Target()
        /// Words past the last region wait for a region of their own (whitespace alone waits for more words).
        var needsRegion: Bool {
            !retracted && !abandoned && remainder.contains { !$0.isWhitespace || $0.isNewline }
        }
    }
    private struct PendingEdit {
        var edit: Edit
        var since: ContinuousClock.Instant
        var done: CheckedContinuation<EditResult, Never>
    }
    private var runs: [Run] = []
    private var edits: [PendingEdit] = []
    private var editRegions: [(region: Region, done: CheckedContinuation<EditResult, Never>)] = []
    private var pump: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var flushing = 0
    private var exclusive = false
    private var operations = FieldEditCoordinator.Operations()
    private var recovery = FieldRecovery()
    private var recoveredRead = false
    private var operationsAt: ContinuousClock.Instant?

    private func advanceOperations() {
        let at = now()
        if let operationsAt {
            let elapsed = (at - operationsAt).components
            operations.advance(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        operationsAt = at
    }

    private func beginOperation(_ kind: FieldEditCoordinator.Operations.Kind, transit: Duration = .zero) -> Bool {
        advanceOperations()
        let parts = transit.components
        return operations.begin(kind, transitMs: Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }

    private func operationDispatched() {
        operations.dispatched()
        operationsAt = now()
    }

    @discardableResult private func confirmOperation(_ matches: Bool) -> Bool {
        advanceOperations()
        return operations.confirm(matches: matches)
    }

    private var userActedFlag = false
    /// The caret the user expects (nil until first read).
    private var userCaret: UTF16Range?
    /// The selection the queue last left or saw; a different one on the next read is the user's.
    /// Selections the queue's own ops may have left (an op that did not read back yet may or may not have landed).
    private var expectedSelections: [UTF16Range] = []
    private var blockedSince: ContinuousClock.Instant?
    private var opsSent = 0
    /// Keystroke fields: the last key sent, for the settle at a move/edit transition.
    private var lastKey: (kind: KeyKind, at: ContinuousClock.Instant)?
    private var lastMoveConfirmed = false
    /// Keystroke fields: the caret is away from where the user expects it (a jump that still has to come back).
    private var caretOwed = false
    /// Keystroke fields: arrows that did not read back in a row.
    private var moveFailures = 0
    /// A modifier is held: the queue waits without counting toward `parkLimit` (a held push-to-talk key).
    private var holding = false
    /// Keystroke fields: a key that did not read back in time (or whose caret lags), the selection it would leave, and
    /// how long it may still show.
    private var lateKey: (at: ContinuousClock.Instant, selection: UTF16Range, limit: Duration, edit: Bool)?
    /// Keystroke fields: the caret the field still reported after an edit key's text showed, and where that key put
    /// the real caret; while it reads so, one arrow makes the field report its caret afresh before anything else.
    private var staleCaret: (reported: UTF16Range, believed: UTF16Range?)?
    /// The late edit key's text showed (its caret may still be the one from before it).
    private var lateKeyLanded = false
    /// Keystroke fields: a caret set the field reported but never proved (`CaretJumps.Direct.tentative`) put the caret
    /// here; the next edit there first proves it with one arrow.
    private var probeAt: Int?
    /// Keystroke fields: the target of the current move, and the jumps spent on it.
    private var jumpGoal: UTF16Range?
    private var jumpsSpent = 0
    /// Hops that missed toward the current target are not repeated for it (a wrapped line's Command+Left stays put).
    private var missedHops: Set<CaretHop> = []
    /// What each keystroke field showed about moving its caret, by `TextTarget.fieldKey` (bounded).
    private static var memory: [AnyHashable: CaretJumps] = [:]
    /// Keystroke fields: the last input mark seen, and when the user's real input last showed.
    private var lastMark: Int?
    private var inputAt: ContinuousClock.Instant?
    /// The target was bound to a newly focused element: the next read finds the work in it again (`adoptRebind`). The
    /// value is the caret the user expected in the element before.
    private var rebindPending: UTF16Range??
    /// The field's length at the last read.
    private var lastLength: Int?
    /// Why the field could not take an op, journaled once per blocked stretch.
    private var blockedNote: String?
    /// Since when the focused field has not read, without a read in between (`unreadableGrace`).
    private var unreadableSince: ContinuousClock.Instant?

    // MARK: Inspection

    public var hasWork: Bool {
        let speaking = runs.contains(where: \.speaking)
        return caretOwed || (!speaking && (!edits.isEmpty || editRegions.contains { $0.region.pending }))
            || runs.contains { run in (!speaking || run.speaking) && (run.needsRegion || run.regions.contains(where: \.pending)) }
    }
    /// The last run region (text and range) when it ends at the user's caret: the dictation Magic may call "what I said".
    public var lastRegionAtCaret: (range: UTF16Range, text: String)? {
        guard let region = runs.last?.regions.last, !region.lost, let caret = userCaret, caret.length == 0, region.end == caret.location
        else { return nil }
        return (UTF16Range(location: region.start, length: region.end - region.start), String(region.current))
    }
    /// What this field showed so far about moving its caret (remembered across bindings of the same field).
    public var caretJumps: CaretJumps {
        get { target?.fieldKey.flatMap { Self.memory[$0] } ?? localJumps }
        set {
            guard let key = target?.fieldKey else { localJumps = newValue; return }
            if Self.memory[key] == nil, Self.memory.count >= 64, let any = Self.memory.keys.first { Self.memory[any] = nil }
            Self.memory[key] = newValue
        }
    }
    /// A field with no `fieldKey`: what it showed is kept for this binding only.
    private var localJumps = CaretJumps()
    public var debugState: String {
        let regions = runs.flatMap(\.regions).map { "\($0.runID ?? $0.id)@\($0.start)[\(String($0.current))→\(String($0.desired))]\($0.open ? "o" : "")\($0.lost ? "x" : "")" }
        return "rev=\(revision) owed=\(caretOwed) caret=\(userCaret.map { "\($0.location)+\($0.length)" } ?? "-") edits=\(edits.count)+\(editRegions.count) regions=\(regions)"
    }

    // MARK: Enqueue

    /// A live run's newest text (a snapshot, a growing take, a typed line). Older versions of a run are ignored.
    /// `fast`: typed at the fast end of the pace (still one grapheme per op), for a finished take inserted at once.
    /// `complete`: this is the run's last text (it can then be undone as a change of its own, `undo()`).
    public func live(runID: String, version: Int, text: String, fast: Bool = false, complete: Bool = false, speaking: Bool = false) {
        let index = runs.firstIndex { $0.id == runID } ?? {
            runs.append(Run(id: runID))
            // New dictation is a new change: whatever was undone can no longer be redone.
            if !redoing { undone = [] }
            ledger.append(.run(runID))
            return runs.count - 1
        }()
        guard !runs[index].retracted, !runs[index].abandoned, version > runs[index].version else { return }
        if complete, !runs[index].complete { runs[index].complete = true; historyChanged() }
        // A new run closes the open region of earlier runs: its words start where the user's caret is.
        if runs[index].regions.isEmpty, runs[index].version < 0 {
            for other in runs.indices where other != index { close(&runs[other], cause: "newRun") }
        }
        // A key or click the queue has not read yet already closed the open region: new words wait for the user's caret.
        if userActedFlag { for other in runs.indices { close(&runs[other], cause: "input") } }
        runs[index].version = version
        if fast { runs[index].fast = true }
        runs[index].speaking = speaking && !complete
        let delivery = runs[index].speechTarget.update(Array(text), speaking: runs[index].speaking)
        retarget(&runs[index], to: delivery)
        note(.live, id: nil, run: runID, text: text, detail: "v\(version)")
        historyChanged()
        schedule()
    }

    /// Mic-off releases the latest coalesced correction even before the final cleanup snapshot arrives.
    public func takeStopped(_ runID: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].speaking = false
        let final = runs[index].speechTarget.authoritative
        let delivery = runs[index].speechTarget.update(final, speaking: false)
        retarget(&runs[index], to: delivery)
        schedule()
    }

    /// Takes a run's text back out: the field shows what was there before it (its initial selection, if any).
    public func retract(runID: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].retracted = true
        runs[index].speaking = false
        runs[index].remainder = []
        for (offset, region) in runs[index].regions.enumerated() where !region.lost {
            region.retracting = true; region.open = false
            region.separator = []; region.source = []
            region.desired = offset == 0 ? Array(region.original) : []
        }
        note(.live, id: nil, run: runID, text: "", detail: "retract")
        historyChanged()
        schedule()
    }

    /// Lands an edit and returns once it was applied or dropped.
    public func edit(_ edit: Edit) async -> EditResult {
        let result = await land(edit)
        if case .applied(let range) = result { record(edit, landed: range) }
        return result
    }

    private func land(_ edit: Edit) async -> EditResult {
        guard target != nil else { return .dropped(.cannotPlace) }
        note(.edit, id: edit.id, text: edit.target, detail: "scope=\(edit.scope)")
        return await withCheckedContinuation { done in
            edits.append(PendingEdit(edit: edit, since: now(), done: done))
            schedule()
        }
    }

    // MARK: History

    /// Legato's own changes to the field, oldest first: dictated runs and edits (Magic). `undo()` takes the last one back
    /// through the queue like any other change; `redo()` puts the last one taken back.
    private struct Change { var edit: Edit; var range: UTF16Range }
    private enum Entry { case run(String), edit(Change) }
    private enum Undone { case run(String), edit(Change) }
    private var ledger: [Entry] = []
    private var undone: [Undone] = []
    private var redoing = false
    /// Called when `canUndo` or `canRedo` may have changed.
    public var onHistoryChange: (@MainActor () -> Void)?

    public var canUndo: Bool { ledger.contains { undoable($0) } }
    public var canRedo: Bool { !undone.isEmpty }

    private func undoable(_ entry: Entry) -> Bool {
        switch entry {
        case .edit: return true
        case .run(let id):
            guard let run = runs.first(where: { $0.id == id }), run.complete, !run.retracted else { return false }
            return run.regions.contains { !$0.current.isEmpty }
        }
    }

    private func historyChanged() { onHistoryChange?() }

    /// An edit that landed is a change of its own, unless it is exactly the inverse of the last one (an undo made
    /// elsewhere, Magic's own): that one is taken back instead.
    private func record(_ edit: Edit, landed: UTF16Range) {
        if case .edit(let last)? = ledger.last, last.edit.target == edit.scope, last.edit.scope == edit.target, !redoing {
            ledger.removeLast()
            undone.append(.edit(last))
        } else {
            if !redoing { undone = [] }
            ledger.append(.edit(Change(edit: edit, range: landed)))
        }
        historyChanged()
    }

    /// Takes Legato's last change back: a finished dictated run goes out again (as `retract`), an edit is reversed. False
    /// when there was nothing to undo or the text no longer allows it.
    @discardableResult public func undo() async -> Bool {
        guard let index = ledger.lastIndex(where: { undoable($0) }) else { return false }
        return await takeBack(at: index)
    }

    private func takeBack(at index: Int) async -> Bool {
        switch ledger[index] {
        case .run(let id):
            guard let run = runs.first(where: { $0.id == id }) else { return false }
            let text = String(run.target)
            ledger.remove(at: index)
            // Regions an edit took over (Magic rewrote words of the take) are no longer followed: they come out as edits
            // of their last known text, found again at their place or uniquely elsewhere.
            let stale = run.regions.filter { $0.lost && !$0.current.isEmpty }
            let followed = run.regions.contains { !$0.lost }
            retract(runID: id)
            var taken = followed
            for (offset, region) in stale.enumerated().reversed() {
                let original = region === run.regions.first ? String(region.original) : ""
                let result = await land(Edit(range: .init(location: region.start, length: region.end - region.start), scope: String(region.current),
                                             before: region.before, after: region.after, target: original, caretAfter: offset == 0))
                if case .applied = result { taken = true }
            }
            guard taken else { historyChanged(); return false }
            undone.append(.run(text))
        case .edit(let change):
            ledger.remove(at: index)
            let reverse = Edit(range: change.range, scope: change.edit.target, before: change.edit.before, after: change.edit.after,
                               target: change.edit.scope, caretAfter: true)
            guard case .applied = await land(reverse) else { historyChanged(); return false }
            undone.append(.edit(change))
        }
        historyChanged()
        await whenIdle()
        return true
    }

    /// Puts back what `undo()` took out last. False when there was nothing to redo or it can no longer be placed.
    @discardableResult public func redo() async -> Bool {
        guard let last = undone.popLast() else { return false }
        redoing = true
        defer { redoing = false }
        switch last {
        case .run(let text):
            live(runID: UUID().uuidString, version: 1, text: text, complete: true)
        case .edit(let change):
            let again = Edit(range: change.range, scope: change.edit.scope, before: change.edit.before, after: change.edit.after,
                             target: change.edit.target, caretAfter: true)
            guard case .applied(let range) = await land(again) else { historyChanged(); return false }
            ledger.append(.edit(Change(edit: change.edit, range: range)))
        }
        historyChanged()
        await whenIdle()
        return true
    }

    /// Runs `body` (the panel's typed insert) once everything before it landed; nothing else goes out meanwhile.
    public func exclusive<T>(label: String, text: String, _ body: @MainActor () async -> T) async -> T {
        note(.typed, id: label, text: text)
        await whenIdle()
        while !beginOperation(.read) { await sleep(Self.waitTick) }
        exclusive = true
        defer { operations.finishRead(); exclusive = false; schedule() }
        return await body()
    }

    /// The user typed or clicked: the next read takes their caret and text as they are, and the open region closes.
    public func userActed() {
        userActedFlag = true
        inputAt = now()
        note(.user)
        if hasWork { schedule() }
    }

    /// Everything pending goes out now, unpaced. Returns once the queue is idle.
    public func flush() async {
        flushing += 1
        defer { flushing -= 1 }
        schedule()
        await whenIdle()
    }

    /// Returns once nothing is pending (landed or dropped).
    public func whenIdle() async {
        guard pump != nil || hasWork else { return }
        schedule()
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The field went away: everything pending is dropped.
    public func reset(_ reason: Reason = .cancelled) {
        dropAll(reason)
        runs = []
        ledger = []; undone = []
        historyChanged()
        note(.reset, reason: reason.rawValue)
    }

    // MARK: Pump

    private func schedule() {
        guard pump == nil, !exclusive else { return }
        pump = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        var idleSteps = 0
        // A park window never carries over from an earlier stretch of work.
        blockedSince = nil; blockedNote = nil
        while hasWork, !exclusive {
            defer { finishEdits() }
            let sent = opsSent
            // Steps that only re-plan (no op) are bounded: past a few, the queue waits like a blocked field.
            if await step(), opsSent > sent || idleSteps < 8 {
                if opsSent > sent { idleSteps = 0; blockedSince = nil; blockedNote = nil } else { idleSteps += 1 }
            } else if holding {
                // Keys wait for the user's modifier to come up; that is not a field that went away.
                idleSteps = 0; blockedSince = nil
                await sleep(Self.waitTick)
            } else {
                idleSteps = 0
                let started = blockedSince ?? now()
                blockedSince = started
                // A focused field that does not read: dictation goes on in the panel, never dropped for focus.
                if let since = unreadableSince, let onUnreadable, now() - since >= Self.unreadableGrace,
                   runs.indices.contains(where: handable) {
                    caretOwed = false
                    unreadableSince = nil
                    onUnreadable(handOver())
                    continue
                }
                if now() - started >= Self.parkLimit {
                    // Everything waiting drops once; later work gets a park window of its own.
                    dropAll(.focusLost)
                    blockedSince = nil; blockedNote = nil
                    break
                }
                await sleep(Self.waitTick)
            }
        }
        finishEdits()
        pump = nil
        if !hasWork {
            onIdle?()
            let waiters = idleWaiters; idleWaiters = []; waiters.forEach { $0.resume() }
        }
        else if !exclusive { schedule() }
    }

    // MARK: Step

    private struct Document {
        let base: Int
        let text: NSString
        let length: Int
        func string(_ location: Int, _ length: Int) -> String? {
            let lower = location - base
            guard lower >= 0, length >= 0, lower + length <= text.length else { return nil }
            return text.substring(with: NSRange(location: lower, length: length))
        }
        func context(before location: Int, _ count: Int) -> String {
            let lower = max(base, location - count)
            return string(lower, location - lower) ?? ""
        }
        func context(after location: Int, _ count: Int) -> String {
            let upper = min(base + text.length, location + count)
            return string(location, max(0, upper - location)) ?? ""
        }
        /// Every absolute location where `needle` occurs.
        func find(_ needle: String) -> [Int] {
            guard !needle.isEmpty else { return [] }
            var found: [Int] = []
            var range = NSRange(location: 0, length: text.length)
            while range.length > 0 {
                let hit = text.range(of: needle, options: .literal, range: range)
                guard hit.location != NSNotFound else { break }
                found.append(base + hit.location)
                let next = hit.location + 1
                range = NSRange(location: next, length: text.length - next)
            }
            return found
        }
    }

    private func read(_ target: any TextTarget, cap: Int = MacFieldQueue.readCap) -> (Document, UTF16Range)? {
        guard let selection = try? target.selectedRange(), let length = try? target.textLength() else { return nil }
        var base = 0, count = length
        if length > cap {
            base = max(0, min(length - cap, selection.location - cap / 2))
            count = cap
        }
        guard let text = try? target.text(in: UTF16Range(location: base, length: count)) else { return nil }
        return (Document(base: base, text: Self.folded(text, keyed: Self.keyed(target)) as NSString, length: length), selection)
    }

    private static func keyed(_ target: any TextTarget) -> Bool { !target.editsInPlace && target.typesKeys }

    /// Keystroke fields: a rich editor shows a typed space as a no-break space (Chromium does at the end of a line, and
    /// turns it back once more text follows). The queue reads both as a space, so its own spaces are recognised.
    static func folded(_ text: String, keyed: Bool) -> String {
        keyed && text.contains("\u{00A0}") ? text.replacingOccurrences(of: "\u{00A0}", with: " ") : text
    }

    /// One op at most. False when the field cannot take one now (unfocused, unreadable, an edit not yet placeable).
    private func step() async -> Bool {
        holding = false
        guard let target else { return false }
        // Real input after this mark refuses a key planned from this read.
        let mark = target.inputMark
        guard focus(target) else { return false }
        guard let (doc, selection) = read(target).map({ ($0.0, $0.1) }) else { blocked("unreadable"); return false }
        unreadableSince = nil
        if let caret = rebindPending {
            rebindPending = nil
            adoptRebind(doc, selection: selection, caret: caret)
        }
        lastLength = doc.length
        let keyed = !target.editsInPlace && target.typesKeys
        // A caret that moved with no real input while a key of ours may still land is that key's, not the user's.
        noteUser(selection: selection, doc: doc, ownKey: keyed && lateKey != nil && (lastMark == nil || mark == lastMark))
        locateAll(doc)
        // Recovery acquired a new observation; no write is planned against the document read before it.
        if recoveredRead { recoveredRead = false; return true }
        // Placing a background edit can claim a run's regions or trigger a recovery read. It waits with the edit,
        // so it cannot steal ownership from the new speech that the scheduler has put first.
        if !runs.contains(where: \.speaking) { placeEdits(doc) }
        if recoveredRead { recoveredRead = false; return true }
        finishEdits()
        if keyed {
            if mark != lastMark {
                if lastMark != nil { inputAt = now() }
                lastMark = mark
                // Real input moves the real caret: a pending proof or refresh would prove nothing now.
                probeAt = nil; staleCaret = nil
            }
            // The user is typing or clicking: keys wait until they rest (without counting toward `parkLimit`).
            if let input = inputAt, now() - input < Self.keyQuiet { holding = true; return false }
        }
        if keyed, let late = lateKey {
            // Never a second key while the last one may still land.
            if selection != late.selection, now() - late.at < late.limit { return false }
            // A key that showed late was no failure.
            if selection == late.selection { moveFailures = 0 }
            // An edit key whose caret never showed: the caret read may be the one from before it. One arrow makes the
            // field report afresh before anything is planned from it.
            else if late.edit, lateKeyLanded { staleCaret = (selection, late.selection) }
            lateKey = nil
        }
        if let stale = staleCaret, stale.reported != selection { staleCaret = nil }
        if let probe = probeAt, selection != UTF16Range(location: probe, length: 0) { probeAt = nil }
        if let region = nextRegion() {
            if keyed { return await performKey(region, doc: doc, selection: selection, target: target, mark: mark) }
            return await perform(region, doc: doc, target: target)
        }
        if openRemainderRegion(doc) { return true }
        if keyed, caretOwed { return await restoreCaret(doc: doc, selection: selection, target: target, mark: mark) }
        caretOwed = false
        return false
    }

    // MARK: Focus

    /// Whether the field the work is for has focus now, binding the editor's fresh element if the page replaced it, for a
    /// caller about to read the field (Magic). `allowOther`: another field of the same app may be bound.
    public func ensureFocused(allowOther: Bool = false) -> Bool {
        guard let target else { return false }
        return focus(target, allowOther: allowOther)
    }

    /// Whether anything of this queue's work is in the field (or about to be): then only the same editor is bound again.
    private var wroteAnything: Bool {
        !edits.isEmpty || !editRegions.isEmpty
            || runs.contains { run in run.regions.contains { !$0.lost && (!$0.current.isEmpty || !$0.original.isEmpty) } }
    }

    /// The bound element has focus, or the target was bound to the element that has it now: the same editor (a web page
    /// recreates elements and moves focus between nested ones as its DOM changes), or, while nothing was written yet,
    /// whichever text field the user is in. Work then goes on there (`adoptRebind` on the next read). Anything else
    /// waits (and drops once after `parkLimit`).
    private func focus(_ target: any TextTarget, allowOther: Bool? = nil) -> Bool {
        if target.isFocused() { return true }
        switch target.refocus(allowOther: allowOther ?? !wroteAnything) {
        case .rebound(let same):
            if !same { reassessedWriteFailure = false }
            note(.rebound, detail: same ? "same editor" : "other field")
            if rebindPending == nil { rebindPending = .some(userCaret) }
            // A move under way is planned again from the new element's caret.
            jumpGoal = nil; jumpsSpent = 0; missedHops = []
            blockedNote = nil
            return true
        case .declined: blocked("otherField"); return false
        case .lost: blocked("notFocused"); return false
        case .unreadable: blocked("unreadable"); return false
        }
    }

    private func blocked(_ why: String) {
        if why == "unreadable" { unreadableSince = unreadableSince ?? now() } else { unreadableSince = nil }
        guard blockedNote != why else { return }
        blockedNote = why
        note(.waiting, reason: why)
    }

    /// The first read of a newly bound element: work that typed nothing yet starts again at its caret; typed work moves by
    /// the one shift under which all of it shows (a nested element's text starts elsewhere), and the carets with it.
    /// Work that does not show is found again, or not, like on any read (`locate`).
    private enum ShiftPass: CaseIterable { case fitted, landed, any }

    private func adoptRebind(_ doc: Document, selection: UTF16Range, caret old: UTF16Range?) {
        for index in runs.indices {
            while let last = runs[index].regions.last, !last.lost, last.current.isEmpty, last.original.isEmpty {
                runs[index].regions.removeLast()
                runs[index].remainder = last.source + runs[index].remainder
            }
        }
        let followed = allRegions.filter { !$0.lost && !$0.current.isEmpty }
        let anchored = allRegions.filter { !$0.lost }
        /// The region's text at `start`, or what an op of its that may land late leaves; empty text only by the text around
        /// it. A text before or after one op can also show a character off inside the other, so passes: `.fitted` wants the
        /// text around it as it was too (a nested element may cut it at its start), `.landed` takes the late op's text when
        /// there is one (it usually landed), `.any` takes either.
        func shows(_ region: Region, at start: Int, _ pass: ShiftPass) -> Bool {
            let texts = pass == .landed ? [region.landing ?? region.current] : [region.current] + (region.landing.map { [$0] } ?? [])
            return texts.contains { text in
                let length = String(text).utf16.count
                guard text.isEmpty || doc.string(start, length) == String(text) else { return false }
                return pass != .fitted && !text.isEmpty || fits(region, at: start, length: length)
            }
        }
        /// The text around the region (`before` ending at `start`, `after` following its text) is what it was. Before it:
        /// all the element's text there ends what was before it (a nested element starts later), or the same full context.
        func fits(_ region: Region, at start: Int, length: Int? = nil) -> Bool {
            let end = start + (length ?? String(region.current).utf16.count)
            guard start >= 0, end <= doc.length else { return false }
            let before = doc.context(before: start, region.before.utf16.count), after = doc.context(after: end, region.after.utf16.count)
            let full = region.before.utf16.count >= Self.contextChars
            return region.before.hasSuffix(before) && (before.utf16.count == start || full && before == region.before)
                && (after == region.after || Self.tailMatches(old: region.after, oldAtEnd: region.afterAtEnd, new: after,
                                                              newAtEnd: end + after.utf16.count == doc.length))
        }
        // The element's text can start elsewhere (focus went into a nested element or out to its root): one shift for all,
        // the first candidate under which all the typed work shows. Candidates: the change in length, the caret (where the
        // user had it, or where a late key of ours put it), the unique place of the longest typed text or of an edit's scope.
        var candidates: [Int] = []
        if let lastLength { candidates.append(doc.length - lastLength) }
        if selection.length == 0 {
            if let old, old.length == 0 { candidates.append(selection.location - old.location) }
            if let late = lateKey { candidates.append(selection.location - late.selection.location) }
        }
        // Typed text found once: long enough, or short with the text around it as it was.
        for region in followed.sorted(by: { $0.current.count > $1.current.count }) {
            let hits = doc.find(String(region.current))
            if hits.count == 1, region.current.count >= Self.relocateMinimum || fits(region, at: hits[0]) {
                candidates.append(hits[0] - region.start)
            }
        }
        for pending in edits {
            let hits = doc.find(pending.edit.scope)
            if hits.count == 1 { candidates.append(hits[0] - pending.edit.range.location) }
        }
        // A fresh element for the same text, the most common case, when nothing above showed it.
        candidates.append(0)
        // Edits not placed yet were read in the old element: their scope shows under the same shift.
        func placed(_ edit: Edit, _ delta: Int) -> Bool { doc.string(edit.range.location + delta, edit.range.length) == edit.scope }
        func holds(_ delta: Int, _ pass: ShiftPass) -> Bool {
            anchored.allSatisfy { shows($0, at: $0.start + delta, pass) } && edits.allSatisfy { placed($0.edit, delta) }
        }
        let shift = anchored.isEmpty && edits.isEmpty ? nil
            : ShiftPass.allCases.lazy.compactMap { pass in candidates.first { holds($0, pass) } }.first
        if let shift {
            for index in edits.indices {
                edits[index].edit.range.location += shift
                // The context before it may start before the new element's text.
                let before = edits[index].edit.before as NSString, room = edits[index].edit.range.location
                if before.length > room { edits[index].edit.before = before.substring(from: before.length - max(0, room)) }
            }
        }
        for region in allRegions where !region.lost {
            guard let shift, shows(region, at: region.start + shift, .any) else { continue }
            region.start += shift
            // The context after it stays as it was (a late key's landing is judged by it on the next locate); the context
            // before it may start before the new element's text.
            let before = doc.context(before: region.start, region.before.utf16.count)
            if before != region.before, region.before.hasSuffix(before) { region.before = before }
        }
        note(.rebound, selection: selection, detail: shift.map { "shift \($0)" } ?? "unanchored")
        guard let shift else {
            // Nothing typed to go by: the element's caret is where the work goes.
            userCaret = selection; expectedSelections = [selection]
            caretOwed = false; lateKey = nil; staleCaret = nil; probeAt = nil
            for index in runs.indices { close(&runs[index], cause: "rebind") }
            return
        }
        // Every caret the queue knows moves with the text. Whether the caret read now is the user's is decided as on any
        // read (`noteUser`): a key or click of theirs, or a caret none of the queue's ops left.
        func moved(_ range: UTF16Range) -> UTF16Range { UTF16Range(location: range.location + shift, length: range.length) }
        userCaret = userCaret.map(moved)
        expectedSelections = expectedSelections.map(moved)
        if let late = lateKey { lateKey?.selection = moved(late.selection) }
        if let stale = staleCaret { staleCaret = (moved(stale.reported), stale.believed.map(moved)) }
        probeAt = probeAt.map { $0 + shift }
    }

    private func noteUser(selection: UTF16Range, doc: Document, ownKey: Bool = false) {
        let moved = !ownKey && !expectedSelections.isEmpty && !expectedSelections.contains(selection)
        if userActedFlag || moved {
            userActedFlag = false
            probeAt = nil; staleCaret = nil
            userCaret = selection
            caretOwed = false
            revision += 1
            for index in runs.indices { close(&runs[index], cause: moved ? "cursor" : "input") }
            for region in allRegions { region.nativePlan = nil }
            note(.user, selection: selection, detail: moved ? "moved" : "acted")
        }
        // A caret past the text (work that did not land after all) is the field's own caret again.
        if userCaret == nil || (userCaret.map { $0.location + $0.length > doc.length } ?? false) { userCaret = selection }
        // A key that may still land leaves its selection ours until it shows or its window passes.
        expectedSelections = [selection] + (lateKey.map { [$0.selection] } ?? [])
    }

    private var allRegions: [Region] { editRegions.map(\.region) + runs.flatMap(\.regions) }

    private func locateAll(_ doc: Document) {
        let speaking = Set(runs.filter(\.speaking).map(\.id))
        for region in allRegions where !region.lost {
            // Locating can search the document and acquire recovery evidence. Deferred edits and older runs do
            // that when speech stops, rather than making the readable new head wait on their stale locations.
            if !speaking.isEmpty, region.runID.map({ !speaking.contains($0) }) ?? true { continue }
            locate(region, doc)
        }
        // A run region that lost its place before any of its words went in starts again at the user's caret.
        for index in runs.indices {
            while let last = runs[index].regions.last, last.lost, last.current.isEmpty, last.original.isEmpty {
                runs[index].regions.removeLast()
                runs[index].remainder = last.source + runs[index].remainder
            }
        }
    }

    private func locate(_ region: Region, _ doc: Document) {
        let length = String(region.current).utf16.count
        if let landing = region.landing {
            region.landing = nil
            let landingLength = String(landing).utf16.count
            // The landed text, with what followed the region still right after it (a prefix of the old text is not it).
            let tail = region.start + landingLength
            if doc.string(region.start, landingLength) == String(landing), landing != region.current,
               Self.tailMatches(old: region.after, oldAtEnd: region.afterAtEnd,
                                new: doc.context(after: tail, Self.contextChars), newAtEnd: tail + doc.context(after: tail, Self.contextChars).utf16.count == doc.length) {
                let follows = region.open && userCaret == UTF16Range(location: region.end, length: 0)
                apply(region, landed: landing)
                if lateKey?.edit == true { lateKeyLanded = true }
                if follows || (region.caretAfter && region.current == region.desired) { userCaret = UTF16Range(location: region.end, length: 0) }
                refreshContext(region, doc)
                return
            }
            // A late key keeps its landing until it shows or its window passes.
            if lateKey != nil { region.landing = landing }
        }
        if doc.string(region.start, length) == String(region.current), contextHolds(region, doc) {
            refreshContext(region, doc); return
        }
        if let found = relocate(region, doc) {
            note(.relocated, id: region.id, run: region.runID, location: found, detail: "from \(region.start)")
            region.start = found
            region.nativePlan = nil
            refreshContext(region, doc)
            return
        }
        if let recovered = recoverTarget(id: region.id, expected: String(region.current), landed: region.landing.map { String($0) },
                                         before: region.before, after: region.after, observed: doc) {
            switch recovered {
            case .replan(let placement, let fresh):
                region.start = fresh.base + String((fresh.text as String).prefix(placement.range.lowerBound)).utf16.count
                if region.current != Array(placement.text) { region.verifiedWrites += 1 }
                region.uncertainWrite = false
                region.current = Array(placement.text)
                region.nativePlan = nil
                region.keys = nil; region.landing = nil; region.failures = 0
                refreshContext(region, fresh)
                recoveredRead = true
                return
            case .waiting: return
            case .stop: break
            }
        }
        region.lost = true
        // An empty run region is placed again (`locateAll`); anything else was changed under it. The run's later words
        // start a region of their own at the user's caret.
        if region.runID != nil, region.current.isEmpty, region.original.isEmpty { return }
        region.open = false
        if region.current != region.desired { drop(region, .userChanged) }
    }

    private enum RecoveryResult { case replan(FieldRecovery.Placement, Document), waiting, stop }

    /// Accessibility can obtain fresh bounded evidence without moving the user's cursor. The same policy used by
    /// the proxy adapter decides whether the expected target, or a freshly observed late result, still exists.
    private func recoverTarget(id: String, expected: String, landed: String? = nil, before: String, after: String,
                               observed: Document) -> RecoveryResult? {
        guard let target, target.isFocused() else { return nil }
        guard beginOperation(.read) else { return .waiting }
        defer { operations.finishRead() }
        let mark = target.inputMark, requestRevision = UInt64(max(0, revision)), start = now()
        let generation = documentID
        let wanted = FieldRecovery.Target(id: id, expected: expected, landed: landed, before: before, after: after)
        guard let request = recovery.begin(generation: generation, revision: requestRevision, targets: [wanted]) else { return nil }
        note(.recovery, id: id, detail: "attempt \(request.id)")
        // The initial queue observation may already contain two indistinguishable candidates. Looking only near
        // the caret would hide the other one, not prove which is owned. Refresh the full original scope instead.
        let wasComplete = observed.base == 0 && observed.text.length == observed.length
        let knownAmbiguity = recovery.hasAmbiguity(request, text: observed.text as String, completeDocument: wasComplete)
        let cap = knownAmbiguity ? Self.readCap : 2 * FieldRecovery.nearbyLimit(for: request)
        guard let oldSelection = try? target.selectedRange(), var (fresh, selected) = read(target, cap: cap),
              let restored = try? target.selectedRange(), oldSelection == selected, selected == restored,
              target.isFocused(), target.inputMark == mark,
              now() - start < .milliseconds(FieldRecovery.budgetMs) else {
            note(.recovery, id: id, reason: "unreadableOrChanged", detail: "refused \(request.id)")
            return .stop
        }
        var complete = fresh.base == 0 && fresh.text.length == fresh.length
        if !recovery.canResolve(request, text: fresh.text as String, completeDocument: complete), !complete,
           let (wider, selection) = read(target), selection == oldSelection,
           (try? target.selectedRange()) == oldSelection, target.inputMark == mark, target.isFocused(),
           now() - start < .milliseconds(FieldRecovery.budgetMs) {
            fresh = wider
            complete = fresh.base == 0 && fresh.text.length == fresh.length
        }
        note(.recovery, id: id, detail: "evidence \(fresh.text.length) restored \(request.id)")
        let decisions = recovery.resolve(request, text: fresh.text as String, generation: documentID,
                                         revision: UInt64(max(0, revision)), restored: true, completeDocument: complete)
        guard case .replan(let placement)? = decisions.first else {
            note(.recovery, id: id, reason: "changedOrAmbiguous", detail: "refused \(request.id)")
            return .stop
        }
        note(.recovery, id: id, detail: "unique replan \(request.id)")
        return .replan(placement, fresh)
    }

    /// The text before a region must still end with what was there, unless the user typed right at its edge.
    private func contextHolds(_ region: Region, _ doc: Document) -> Bool {
        guard !region.current.isEmpty else {
            return region.before.isEmpty || doc.context(before: region.start, region.before.utf16.count) == region.before
        }
        return true
    }

    private func relocate(_ region: Region, _ doc: Document) -> Int? {
        let text = String(region.current)
        if region.current.count >= Self.relocateMinimum {
            let hits = doc.find(text)
            if hits.count == 1 { return hits[0] }
        }
        let withBefore = region.before + text
        if !region.before.isEmpty, withBefore.count >= 4 {
            let hits = doc.find(withBefore)
            if hits.count == 1 { return hits[0] + region.before.utf16.count }
        }
        let withAfter = text + region.after
        if !region.after.isEmpty, withAfter.count >= 4 {
            let hits = doc.find(withAfter)
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    private func refreshContext(_ region: Region, _ doc: Document) {
        region.before = doc.context(before: region.start, Self.contextChars)
        region.after = doc.context(after: region.end, Self.contextChars)
        region.afterAtEnd = region.end + region.after.utf16.count == doc.length
    }

    /// Whether the text after an edit is still what followed it before. A rich editor shows an empty last line as a
    /// placeholder line break: it goes when the line gets text and comes when the line empties, so at the end of the
    /// field one trailing line break more or less is the same text.
    static func tailMatches(old: String, oldAtEnd: Bool, new: String, newAtEnd: Bool) -> Bool {
        if new == old { return true }
        guard oldAtEnd, newAtEnd else { return false }
        return (old.hasSuffix("\n") && new == String(old.dropLast())) || new == old + "\n"
    }

    private func placeEdits(_ doc: Document) {
        var waiting: [PendingEdit] = []
        for pending in edits {
            if recoveredRead { waiting.append(pending); continue }
            let edit = pending.edit
            var start: Int?
            if doc.string(edit.range.location, edit.range.length) == edit.scope,
               doc.context(before: edit.range.location, edit.before.utf16.count) == edit.before {
                start = edit.range.location
            } else {
                let hits = doc.find(edit.before + edit.scope + edit.after)
                if hits.count == 1 { start = hits[0] + edit.before.utf16.count }
                else if edit.scope.count >= Self.relocateChars, doc.find(edit.scope).count == 1 { start = doc.find(edit.scope)[0] }
            }
            if start == nil, now() - pending.since >= Self.placeGrace,
               let result = recoverTarget(id: edit.id, expected: edit.scope, before: edit.before, after: edit.after, observed: doc) {
                switch result {
                case .replan:
                    // Coordinates, anchors and overlap ownership must all come from one observation. Let the next
                    // fresh queue read place the still-pending edit; never create its region against this old doc.
                    recoveredRead = true
                    waiting.append(pending)
                    continue
                case .waiting: waiting.append(pending); continue
                case .stop: break
                }
            }
            if let start {
                let region = Region(id: edit.id, runID: nil, start: start, current: Array(edit.scope), desired: Array(edit.target), open: false)
                region.caretAfter = edit.caretAfter
                refreshContext(region, doc)
                // Dictation under the edit's scope is the edit's now: its regions are given up (a pending revision of
                // them is dropped like one the user overwrote).
                let end = region.end
                for other in runs.flatMap(\.regions) where !other.lost {
                    let overlaps = other.current.isEmpty ? (start < other.start && other.start < end) : (other.start < end && start < other.end)
                    guard overlaps else { continue }
                    if other.pending { drop(other, .userChanged) }
                    other.lost = true; other.open = false
                }
                editRegions.append((region, pending.done))
                note(.regionStarted, id: edit.id, location: start, length: edit.range.length)
            } else if now() - pending.since < Self.placeGrace {
                waiting.append(pending)
            } else {
                note(.dropped, id: edit.id, text: edit.target, reason: Reason.cannotPlace.rawValue)
                onDrop?(Drop(id: edit.id, runID: nil, reason: .cannotPlace, text: edit.target))
                pending.done.resume(returning: .dropped(.cannotPlace))
            }
        }
        edits = waiting
    }

    private func stoppedResult(_ region: Region, reason: Reason) -> EditResult {
        if region.verifiedWrites > 0 { return .stopped(reason) }
        // An unconfirmed write is uncertain, even if focus loss is what finally stopped the work.
        if region.uncertainWrite { return .dropped(.failed) }
        return .dropped(reason)
    }

    private func finishEdits() {
        editRegions.removeAll { entry in
            if entry.region.lost { entry.done.resume(returning: stoppedResult(entry.region, reason: entry.region.dropReason)); return true }
            guard !entry.region.pending else { return false }
            let range = UTF16Range(location: entry.region.start, length: entry.region.end - entry.region.start)
            note(.applied, id: entry.region.id, location: range.location, length: range.length)
            entry.done.resume(returning: .applied(range))
            return true
        }
    }

    /// Edits first (the user is waiting on Magic), then dictation in speaking order.
    private func nextRegion() -> Region? {
        if runs.contains(where: \.speaking) {
            // Background edits do not send the caret back through earlier words while the user speaks.
            for run in runs where run.speaking {
                if let region = run.regions.first(where: { $0.open && $0.pending }) { return region }
                if let region = run.regions.first(where: \.pending) { return region }
            }
            return nil
        }
        if let edit = editRegions.first(where: { $0.region.pending })?.region { return edit }
        for run in runs { if let region = run.regions.first(where: \.pending) { return region } }
        return nil
    }

    /// Words of a run with no open region start one at the user's caret.
    private func openRemainderRegion(_ doc: Document) -> Bool {
        guard let index = runs.firstIndex(where: \.needsRegion), let caret = userCaret else { return false }
        let first = runs[index].regions.isEmpty
        // The run's first words replace the user's selection; later regions never eat one.
        let replaced = first ? (doc.string(caret.location, caret.length) ?? "") : ""
        let start = first ? caret.location : caret.location + caret.length
        let previous = doc.context(before: start, 1).last
        let words = first ? runs[index].remainder : Array(runs[index].remainder.drop { $0.isWhitespace && !$0.isNewline })
        guard !words.isEmpty else { return false }
        let separator = Array(PanelTake.separator(before: String(words), after: previous))
        let region = Region(id: UUID().uuidString, runID: runs[index].id, start: start, current: Array(replaced),
                            desired: separator + words, open: true)
        region.source = runs[index].remainder
        region.separator = separator
        region.trimsLead = !first
        region.original = replaced
        refreshContext(region, doc)
        runs[index].regions.append(region)
        runs[index].remainder = []
        // The user's caret follows the open region from here.
        userCaret = UTF16Range(location: region.end, length: 0)
        note(.regionStarted, id: region.id, run: region.runID, location: start, length: replaced.utf16.count)
        return true
    }

    // MARK: Ops

    private var pacedNow: Bool { flushing == 0 && paced() }

    /// Diagnostic count: verified character advances reuse a plan; only a changed target or field rebuilds the diff.
    private(set) var nativePlanBuilds = 0

    private func nativePlan(for region: Region) -> NativeEditPlan {
        if let plan = region.nativePlan, plan.matches(current: region.current, desired: region.desired, paced: pacedNow) { return plan }
        nativePlanBuilds += 1
        let plan = NativeEditPlan(current: region.current, desired: region.desired, paced: pacedNow)
        region.nativePlan = plan
        return plan
    }

    private func perform(_ region: Region, doc: Document, target: any TextTarget) async -> Bool {
        guard beginOperation(.edit) else { return false }
        defer { operations.invalidate() }
        var plan = nativePlan(for: region)
        guard let step = plan.next, let after = plan.afterNext else { return true }
        let lower = step.range.lowerBound, upper = step.range.upperBound
        let insertion = step.replacement
        let location = region.start + String(region.current[..<lower]).utf16.count
        let removed = String(region.current[lower..<upper])
        let range = UTF16Range(location: location, length: removed.utf16.count)
        let text = String(insertion)
        // The caret follows an open region's end when the user's caret was there.
        let follows = region.open && userCaret == UTF16Range(location: region.end, length: 0)
        note(.sent, id: region.id, run: region.runID, location: range.location, length: range.length, text: text,
             read: doc.context(before: range.location, 40) + "|" + doc.context(after: range.location, 40))
        opsSent += 1
        region.uncertainWrite = true
        do {
            try target.replace(range, with: text)
            operationDispatched()
        } catch {
            expectedSelections.append(UTF16Range(location: range.location + text.utf16.count, length: 0))
            return await failed(region, after: after, reason: "write", unchanged: nativeWriteUnchanged(region, doc: doc, target: target))
        }
        // Read back the region and the caret before anything else goes out.
        let shown = try? target.text(in: UTF16Range(location: region.start, length: String(after).utf16.count))
        guard shown == String(after) else {
            // The op may still land: the caret it leaves is ours too.
            expectedSelections.append(UTF16Range(location: range.location + text.utf16.count, length: 0))
            return await failed(region, after: after, reason: "readback", unchanged: nativeWriteUnchanged(region, doc: doc, target: target))
        }
        guard confirmOperation(true), plan.confirm(after) else { region.nativePlan = nil; return false }
        region.nativePlan = plan
        let delta = text.utf16.count - range.length
        apply(region, landed: after, at: range, delta: delta, inserted: text.utf16.count)
        revision += 1
        let natural = UTF16Range(location: range.location + text.utf16.count, length: 0)
        let done = region.current == region.desired
        var wanted: UTF16Range = follows || (done && region.caretAfter) ? UTF16Range(location: region.end, length: 0) : (userCaret ?? natural)
        // A retracted run's first region gives back what it replaced, selected again, so the retry replaces it too.
        if done, region.retracting, !region.original.isEmpty { wanted = UTF16Range(location: region.start, length: region.end - region.start) }
        userCaret = wanted
        let selection = try? target.selectedRange()
        if selection != wanted, beginOperation(.move) {
            try? target.setSelectedRange(wanted)
            operationDispatched()
            _ = confirmOperation((try? target.selectedRange()) == wanted)
            expectedSelections = [(try? target.selectedRange()) == wanted ? wanted : (selection ?? wanted)]
        } else {
            expectedSelections = [wanted]
        }
        note(.verified, id: region.id, run: region.runID, location: region.start, length: region.end - region.start, text: String(region.current),
             selection: wanted)
        if pacedNow, !insertion.isEmpty {
            let remaining = plan.remainingInsertions
            let ops = remaining + typedBacklog(besides: region)
            // Nothing more to type: no wait after the last grapheme.
            if ops > 0 {
                let pace = isFast(region) ? KeystrokePlanner.writeFloorMs
                    : KeystrokePlanner.paceMs(ops: ops, floor: KeystrokePlanner.writeFloorMs)
                await sleep(.milliseconds(pace))
            }
        }
        return true
    }

    // MARK: Keystrokes

    private func isFast(_ region: Region) -> Bool {
        region.runID.flatMap { id in runs.first { $0.id == id }?.fast } ?? false
    }

    /// The region's planned keys, kept while the region's text follows them (a key that read back late moves the unit
    /// on); planned again when the desired text changed or the field shows anything else.
    private func keyUnit(for region: Region, doc: Document) -> KeyUnit? {
        if let unit = region.keys, unit.desired == region.desired {
            for index in unit.index..<min(unit.steps.count, unit.index + 4) where unit.steps[index].before == region.current {
                unit.index = index
                return unit
            }
        }
        let fast = isFast(region)
        let typedMs = fast ? KeystrokePlanner.floorMs : pacedNow ? KeystrokePlanner.calmMs : KeystrokePlanner.keyMs
        let lineStart = doc.context(before: region.start, 1).last?.isNewline ?? true
        let lineEnd = doc.context(after: region.end, 1).first?.isNewline ?? true
        let steps = KeystrokePlanner.steps(from: region.current, to: region.desired, paceMs: typedMs, jumpMs: caretJumps.jumpMs,
                                           lineStart: lineStart, lineEnd: lineEnd)
        guard !steps.isEmpty else { region.keys = nil; return nil }
        let typed = steps.reduce(0) { if case .type = $1.key { $0 + 1 } else { $0 } }
        let fixed = Double(steps.count - typed) * KeystrokePlanner.keyMs
        let unit = KeyUnit(desired: region.desired, steps: steps,
                           paceMs: fast ? KeystrokePlanner.floorMs : KeystrokePlanner.paceMs(ops: typed + typedBacklog(besides: region), fixedMs: fixed))
        region.keys = unit
        note(.planned, id: region.id, run: region.runID, location: region.start, text: String(region.desired),
             detail: "keys=\(steps.count) typed=\(typed) pace=\(Int(unit.paceMs))")
        return unit
    }

    /// One key toward the region's desired text: a caret move while the caret is not where the next edit goes, else the
    /// edit (Backspace or one grapheme). It counts by the field's value: the region's new text at its place, what
    /// followed it still after it, and the field's length. A caret that lags behind a landed key is waited for.
    private func performKey(_ region: Region, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int) async -> Bool {
        defer { operations.invalidate() }
        guard let unit = keyUnit(for: region, doc: doc) else { return true }
        var step = unit.steps[unit.index]
        var caret = region.start + String(step.before[..<step.caret]).utf16.count
        // The field still reports the caret an earlier key left before it showed moving: one arrow makes it report
        // afresh before anything is typed, or planned, from a caret that may not be the real one.
        if let stale = staleCaret, stale.reported == selection {
            staleCaret = nil
            if await settle(before: .move) { return true }
            return await refresh(stale.believed, doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        guard selection == UTF16Range(location: caret, length: 0) else {
            return await move(toward: UTF16Range(location: caret, length: 0), doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        // A caret set the field reported but never proved: one arrow shows whether the real caret followed it.
        if probeAt == caret, caretJumps.direct == .tentative {
            if await settle(before: .move) { return true }
            return await probe(doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        if await settle(before: .edit) { return true }
        let oldTail = doc.context(after: region.end, Self.contextChars)
        let oldAtEnd = region.end + oldTail.utf16.count == doc.length
        var docLength = doc.length
        var piped = 1
        // Typed graphemes go out in runs of a few, more while typing is behind speech.
        let maxRun = unit.typedLeft + typedBacklog(besides: region) >= KeystrokePlanner.behindOps ? Self.pipelineRunBehind : Self.pipelineRun
        while true {
            let after = step.after
            let range: UTF16Range, inserted: String, key: FieldKey
            switch step.key {
            case .backspace:
                let removed = String(step.before[step.caret - 1]).utf16.count
                range = UTF16Range(location: caret - removed, length: removed); inserted = ""; key = .backspace
            case .type(let character):
                range = UTF16Range(location: caret, length: 0); inserted = String(character); key = .text(character)
            }
            let follows = region.open && userCaret == UTF16Range(location: region.end, length: 0)
            note(.sent, id: region.id, run: region.runID, location: range.location, length: range.length, text: inserted,
                 read: piped == 1 ? doc.context(before: range.location, 40) + "|" + doc.context(after: range.location, 40) : nil,
                 detail: piped == 1 ? "key" : "piped key")
            // Every key goes through the guards: focus, no real input since the mark, no modifier, and the caret where
            // this key was planned (for a piped key, where the one before it was seen to leave it).
            guard sendKey(key, target: target, mark: mark, selection: piped == 1 ? selection : UTF16Range(location: caret, length: 0)) == nil
            else { return piped > 1 }
            region.uncertainWrite = true
            let sentAt = now()
            lastKey = (.edit, sentAt)
            probeAt = nil
            let delta = inserted.utf16.count - range.length
            let expected = UTF16Range(location: range.location + inserted.utf16.count, length: 0)
            let window = UTF16Range(location: region.start, length: String(after).utf16.count)
            let lengthNow = docLength + delta

            /// The key's text and caret showed: the region takes it.
            func land(caretSeen: Bool, lastSelection: UTF16Range) {
                _ = confirmOperation(true)
                apply(region, landed: after, at: range, delta: delta, inserted: inserted.utf16.count)
                unit.index += 1
                revision += 1
                if follows || (region.current == region.desired && region.caretAfter) { userCaret = UTF16Range(location: region.end, length: 0) }
                caretOwed = userCaret != expected
                if caretSeen {
                    expectedSelections = [expected]
                } else {
                    // The value shows the key, the caret does not yet: nothing goes out until it does or the window passes.
                    expectedSelections = [expected, lastSelection]
                    lateKey = (sentAt, expected, Self.keyLateLimit, true)
                    lateKeyLanded = true
                    staleCaret = (lastSelection, expected)
                }
                note(.verified, id: region.id, run: region.runID, location: region.start, length: region.end - region.start,
                     text: String(region.current), selection: expected,
                     detail: caretSeen ? nil : "caretLag \(lastSelection.location)+\(lastSelection.length)")
            }

            // A run of typed graphemes is verified by the caret alone, one read per key; the region's text, and the field's
            // length and tail, are read once after the run's last key (the window covers the whole run).
            if piped < maxRun, canPipeline(after: step, unit: unit, region: region, mark: mark, target: target),
               await poll(Self.pipelineWait, { (try? target.selectedRange()) == expected }) {
                land(caretSeen: true, lastSelection: expected)
                docLength = lengthNow
                let pace = min(unit.paceMs, KeystrokePlanner.paceMs(ops: unit.typedLeft + typedBacklog(besides: region)))
                let gap = Duration.milliseconds(pace) - (now() - sentAt)
                if gap > .zero { await sleep(gap) }
                step = unit.steps[unit.index]
                caret = region.start + String(step.before[..<step.caret]).utf16.count
                piped += 1
                continue
            }

            var valueAt: ContinuousClock.Instant?
            var caretSeen = false, transformed = false
            var lastSelection = selection
            _ = await poll(Self.keyConfirm) {
                guard let length = try? target.textLength(), let shown = try? target.text(in: window) else { return false }
                let current = try? target.selectedRange()
                if let current { lastSelection = current }
                let textShows = Self.folded(shown, keyed: true) == String(after)
                if textShows, Self.tailHolds(target, at: window.end, length: length, old: oldTail, oldAtEnd: oldAtEnd, lengthNow: lengthNow) {
                    if current == expected { caretSeen = true; return true }
                    // The key's text is there: it landed. The caret may follow late; it gets a short wait here.
                    let since = valueAt ?? now()
                    valueAt = since
                    return now() - since >= Self.caretWait
                }
                // The caret and length are the key's, the text is not: the host changed what the key typed.
                if !textShows, current == expected, length == lengthNow { transformed = true; return true }
                return false
            }
            if transformed, target.inputMark == mark {
                // Typing again would only repeat the host's change: the region's work stops (its text is recovered).
                note(.mismatch, id: region.id, run: region.runID, reason: "transformed")
                region.lost = true
                drop(region, .failed)
                expectedSelections = [expected]
                return true
            }
            guard valueAt != nil || caretSeen, !transformed else {
                expectedSelections.append(expected)
                if target.inputMark != mark {
                    // The user typed or clicked meanwhile: not the key's failure. The next read takes their input and
                    // finds the key's text where it landed.
                    region.landing = after
                    userActedFlag = true
                    note(.mismatch, id: region.id, run: region.runID, reason: "user", detail: "failures=\(region.failures)")
                    return true
                }
                // The value does not show the key (yet): it may still land, and it is never sent again before it shows or
                // its window passes. Its caret is ours too, and the next read takes its text as landed late.
                lateKey = (sentAt, expected, Self.keyLateLimit, true)
                lateKeyLanded = false
                return await failed(region, after: after, reason: "key")
            }
            land(caretSeen: caretSeen, lastSelection: lastSelection)
            if case .type = step.key, pacedNow {
                // The faster of the change's own pace and the backlog's, counted from when the key went out.
                let pace = min(unit.paceMs, KeystrokePlanner.paceMs(ops: unit.typedLeft + typedBacklog(besides: region)))
                let gap = Duration.milliseconds(pace) - (now() - sentAt)
                // Nothing more to type: no wait after the last grapheme.
                if unit.typedLeft + typedBacklog(besides: region) > 0, gap > .zero { await sleep(gap) }
            }
            return true
        }
    }

    /// Whether the key just sent may be verified by the caret alone, so the next typed grapheme goes straight after it:
    /// both are typed graphemes at one place, the change is still the one planned, and nothing else wants the field.
    private func canPipeline(after step: KeystrokePlanner.Step, unit: KeyUnit, region: Region, mark: Int, target: any TextTarget) -> Bool {
        guard pacedNow, !exclusive, !userActedFlag, !region.lost, unit.desired == region.desired, target.inputMark == mark,
              case .type = step.key, unit.index + 1 < unit.steps.count else { return false }
        let next = unit.steps[unit.index + 1]
        guard case .type = next.key, next.caret == step.caretAfter, next.before == step.after else { return false }
        return true
    }

    /// Whether the text after an edit key's window is what followed the region before, and the field's length fits
    /// (`tailMatches`: one trailing placeholder line break more or less at the end of the field).
    private static func tailHolds(_ target: any TextTarget, at location: Int, length: Int, old: String, oldAtEnd: Bool,
                                  lengthNow: Int) -> Bool {
        let available = max(0, min(length - location, old.utf16.count + 1))
        guard let read = try? target.text(in: UTF16Range(location: location, length: available)) else { return false }
        let tail = folded(read, keyed: true)
        if length == lengthNow, tail.hasPrefix(old) { return true }
        guard oldAtEnd, location + tail.utf16.count == length, abs(length - lengthNow) == 1 else { return false }
        return tailMatches(old: old, oldAtEnd: true, new: tail, newAtEnd: true)
    }

    // MARK: Jumps

    /// One verified step toward `goal`: an Accessibility caret set where the field honours it, a hop toward a far
    /// target, or a run of plain arrows. Whatever lands is read back; the next step goes on from where the field
    /// reports the caret. Jumps per target are bounded (`jumpRounds`); after that only arrows go.
    private func move(toward goal: UTF16Range, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int,
                      region: Region?) async -> Bool {
        if await settle(before: .move) { return true }
        // An unproven caret set is proved before the caret moves on: a second set would hide whether the first took.
        if let probe = probeAt, selection == UTF16Range(location: probe, length: 0), caretJumps.direct == .tentative {
            return await self.probe(doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        if jumpGoal != goal { jumpGoal = goal; jumpsSpent = 0; missedHops = [] }
        let distance = graphemes(doc, from: selection.location, to: goal.location)
        let memory = caretJumps
        let canJump = jumpsSpent < Self.jumpRounds
        // A set that does not read back is refused for the field: it cannot loop.
        if memory.direct != .refused, distance > 1 || selection.length > 0 || goal.length > 0 || memory.direct == .trusted {
            return await caretSet(goal, doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        if goal.length > 0 {
            // Arrows cannot rebuild a selection: the caret goes to its end.
            return await move(toward: UTF16Range(location: goal.end, length: 0), doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        if canJump, selection.length == 0, distance > Self.arrowRun,
           let (hop, predicted) = Self.hop(from: selection.location, to: goal.location, in: doc,
                                             allowed: { Self.safeHops.contains($0) && memory.allows($0) && !self.missedHops.contains($0) }) {
            return await hopMove(hop, predicted: predicted, doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        return await arrows(toward: goal.location, count: min(max(distance, 1), Self.arrowRun), doc: doc, selection: selection,
                            target: target, mark: mark, region: region, purpose: "move")
    }

    /// Graphemes between two offsets of the read text.
    private func graphemes(_ doc: Document, from a: Int, to b: Int) -> Int {
        doc.string(min(a, b), abs(a - b))?.count ?? abs(a - b)
    }

    /// The caret (or a selection) through Accessibility. A set that reads back is used again; one that does not is
    /// never tried again in this field (it may still take within `caretSetLateLimit`; nothing goes out before).
    private func caretSet(_ goal: UTF16Range, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int,
                          region: Region?) async -> Bool {
        guard beginOperation(.move, transit: Self.caretSetLateLimit) else { return false }
        defer { operations.invalidate() }
        note(.sent, id: region?.id, run: region?.runID, location: selection.location, selection: goal, detail: "caret")
        do {
            try target.setCaret(goal, mark: mark, selection: selection)
            operationDispatched()
            opsSent += 1
        } catch {
            let refusal = error as? FieldKeyRefusal ?? .unavailable
            note(.refused, reason: "\(refusal)", detail: "caret")
            if refusal == .unavailable { caretJumps.direct = .refused; return true }
            refused(refusal, target: target, mark: mark)
            return false
        }
        let sentAt = now()
        lastKey = (.move, sentAt)
        lastMoveConfirmed = false
        let took = await poll(Self.caretSetConfirm) {
            (try? target.selectedRange()) == goal && (try? target.textLength()) == doc.length
        }
        if took {
            _ = confirmOperation(true)
            guard target.inputMark == mark else { userActedFlag = true; return true }
            if caretJumps.direct == .untested { caretJumps.direct = .tentative }
            lastMoveConfirmed = caretJumps.direct == .trusted
            probeAt = caretJumps.direct == .tentative && goal.length == 0 ? goal.location : nil
            moveFailures = 0
            expectedSelections = [goal]
            // An unproven set still owes its proof, even where it put the caret back.
            caretOwed = userCaret != goal || probeAt != nil
            return true
        }
        caretJumps.direct = .refused
        note(.mismatch, id: region?.id, run: region?.runID, reason: "caret", detail: "direct refused")
        expectedSelections.append(goal)
        if target.inputMark != mark { userActedFlag = true; return true }
        lateKey = (sentAt, goal, Self.caretSetLateLimit, false)
        return true
    }

    /// One arrow from where the field's stale caret read says the caret is not: the way whose landing (from where the
    /// last key put the real caret) differs from that read. Only that landing counts (a stale read catching up is not
    /// the arrow); until it shows, nothing else goes out.
    ///
    /// With no belief (a caret set that may only have been reported), any landing counts: only a key moves the caret.
    private func refresh(_ believed: UTF16Range?, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int,
                         region: Region?) async -> Bool {
        guard let believed else {
            let right = !doc.context(after: selection.location, 1).isEmpty
            var refusal: FieldKeyRefusal?
            let seen = await sendMove(right ? .right : .left, exact: UTF16Range(location: selection.location + (right ? 1 : -1), length: 0),
                                      left: !right, doc: doc, selection: selection, target: target, mark: mark, region: region,
                                      detail: "refresh", anyWay: true, refusal: &refusal)
            if seen == nil, refusal == nil, target.inputMark == mark { staleCaret = (selection, nil) }
            return refusal == nil
        }
        let at = believed.location
        let next = doc.context(after: at, 32).first.map { String($0).utf16.count }
        let previous = doc.context(before: at, 32).last.map { String($0).utf16.count }
        let right = next.map { at + $0 != selection.location } ?? false || previous == nil
        let exact = UTF16Range(location: right ? at + (next ?? 0) : at - (previous ?? 0), length: 0)
        guard exact != selection, next != nil || previous != nil else { return await refresh(nil, doc: doc, selection: selection, target: target, mark: mark, region: region) }
        var refusal: FieldKeyRefusal?
        _ = await sendMove(right ? .right : .left, exact: exact, left: !right, doc: doc, selection: selection, target: target,
                           mark: mark, region: region, detail: "refresh", exactOnly: true, refusal: &refusal)
        return refusal == nil
    }

    /// One arrow away from a tentative caret set, read back exactly: the real caret followed the set (it is trusted
    /// from now on in this field) or it did not (never used again). The next step goes on from where it is.
    private func probe(doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int, region: Region?) async -> Bool {
        probeAt = nil
        let right = !doc.context(after: selection.location, 1).isEmpty
        let size = (right ? doc.context(after: selection.location, 32).first : doc.context(before: selection.location, 32).last)
            .map { String($0).utf16.count } ?? 1
        let exact = UTF16Range(location: selection.location + (right ? size : -size), length: 0)
        var refusal: FieldKeyRefusal?
        // Any landing counts: where the real caret was is the point.
        let seen = await sendMove(right ? .right : .left, exact: exact, left: !right, doc: doc, selection: selection,
                                  target: target, mark: mark, region: region, detail: "probe", anyWay: true, refusal: &refusal)
        guard let seen else {
            if refusal != nil { probeAt = selection.location; return false }
            // Where the real caret is stays unknown: the caret read may be the set's alone. One arrow finds out first.
            if target.inputMark == mark { caretJumps.direct = .refused; staleCaret = (selection, nil) }
            return true
        }
        // The user's key or click during the probe may have moved the caret: it proves nothing either way.
        guard target.inputMark == mark else { userActedFlag = true; return true }
        caretJumps.direct = seen == exact ? .trusted : .refused
        note(.verified, id: region?.id, run: region?.runID, selection: seen, detail: "probe \(caretJumps.direct.rawValue)")
        return true
    }

    /// One hop toward a far target. Its landing is predicted; where it really lands counts toward whether the field
    /// keeps using that hop (`CaretJumps`).
    private func hopMove(_ hop: CaretHop, predicted: Int, doc: Document, selection: UTF16Range, target: any TextTarget,
                         mark: Int, region: Region?) async -> Bool {
        let exact = UTF16Range(location: predicted, length: 0)
        let left = [CaretHop.wordLeft, .lineStart, .documentStart].contains(hop)
        var refusal: FieldKeyRefusal?
        let seen = await sendMove(.hop(hop), exact: exact, left: left, doc: doc, selection: selection, target: target,
                                  mark: mark, region: region, detail: "hop \(hop.rawValue)", refusal: &refusal)
        if refusal == .unavailable { caretJumps.unsupported.insert(hop); return true }
        if refusal != nil { return false }
        // A hop that lands off its prediction is a correction round (`jumpRounds` per target). Input meanwhile voids it.
        guard target.inputMark == mark else { userActedFlag = true; return true }
        if let seen {
            if seen == exact { caretJumps.hits[hop, default: 0] += 1 } else { caretJumps.misses[hop, default: 0] += 1; jumpsSpent += 1; missedHops.insert(hop) }
        } else if target.inputMark == mark {
            caretJumps.misses[hop, default: 0] += 1; jumpsSpent += 1; missedHops.insert(hop)
        }
        return true
    }

    /// `count` plain arrows toward `goal` (one when a selection collapses).
    private func arrows(toward goal: Int, count: Int, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int,
                        region: Region?, purpose: String) async -> Bool {
        let left: Bool
        let exact: UTF16Range
        var count = count
        if selection.length > 0 {
            left = goal <= selection.location
            exact = UTF16Range(location: left ? selection.location : selection.end, length: 0)
            count = 1
        } else {
            left = goal < selection.location
            let span = left ? Array(doc.context(before: selection.location, 32 * count).reversed())
                            : Array(doc.context(after: selection.location, 32 * count))
            count = max(1, min(count, span.count))
            let units = span.prefix(count).reduce(0) { $0 + String($1).utf16.count }
            exact = UTF16Range(location: selection.location + (left ? -max(units, 1) : max(units, 1)), length: 0)
        }
        let key: FieldKey = count == 1 ? (left ? .left : .right) : .arrows(left: left, count: count)
        var refusal: FieldKeyRefusal?
        _ = await sendMove(key, exact: exact, left: left, doc: doc, selection: selection, target: target, mark: mark,
                           region: region, detail: (left ? "left" : "right") + (count == 1 ? "" : "×\(count)") + (purpose == "move" ? "" : " \(purpose)"),
                           refusal: &refusal)
        return refusal == nil
    }

    /// Sends one move and reads back where it landed: exactly the predicted caret, or a collapsed caret the right way
    /// that held still (the host's word and grapheme boundaries may differ from ours). Returns the landing, or nil
    /// when it was refused or did not read back (then it may still land: nothing goes out before it shows or its
    /// window passes).
    private func sendMove(_ key: FieldKey, exact: UTF16Range, left: Bool, doc: Document, selection: UTF16Range,
                          target: any TextTarget, mark: Int, region: Region?, detail: String, anyWay: Bool = false,
                          exactOnly: Bool = false, refusal: inout FieldKeyRefusal?) async -> UTF16Range? {
        note(.sent, id: region?.id, run: region?.runID, location: selection.location, selection: exact, detail: detail)
        defer { operations.invalidate() }
        if let refused = sendKey(key, target: target, mark: mark, selection: selection) {
            refusal = refused
            return nil
        }
        let sentAt = now()
        lastKey = (.move, sentAt)
        lastMoveConfirmed = false
        probeAt = nil
        var seen: UTF16Range?
        var held: (range: UTF16Range, since: ContinuousClock.Instant)?
        let moved = await poll(Self.keyConfirm) {
            guard let current = try? target.selectedRange(), current != selection, (try? target.textLength()) == doc.length
            else { held = nil; return false }
            if current == exact { seen = current; return true }
            if exactOnly { return false }
            let rightWay = current.length == 0 && (anyWay || selection.length == 0
                && (left ? current.location < selection.location : current.location > selection.location))
            guard rightWay else { held = nil; return false }
            if held?.range != current { held = (current, now()) }
            if let held, now() - held.since >= Self.moveStable { seen = current; return true }
            return false
        }
        guard moved, let seen else {
            expectedSelections.append(exact)
            if target.inputMark != mark {
                // The user typed or clicked meanwhile: the next read takes their caret.
                userActedFlag = true
                return nil
            }
            lateKey = (sentAt, exact, Self.keyLateLimit, false)
            moveFailures += 1
            note(.mismatch, id: region?.id, run: region?.runID, reason: "move", detail: "failures=\(moveFailures)")
            if moveFailures >= Self.retryLimit {
                moveFailures = 0
                if let region { region.lost = true; drop(region, .failed) } else { caretOwed = false }
            }
            await sleep(Self.waitTick)
            return nil
        }
        _ = confirmOperation(true)
        lastMoveConfirmed = seen == exact
        moveFailures = 0
        expectedSelections = [seen]
        caretOwed = userCaret != seen
        // The user's key or click meanwhile: the next read takes their caret and text.
        if target.inputMark != mark { userActedFlag = true }
        if seen != exact { note(.verified, id: region?.id, run: region?.runID, selection: seen, detail: "landed off \(exact.location)") }
        return seen
    }

    /// A hop toward `goal` from `caret` and where it should land, or nil when none helps: Command+Up/Down to the
    /// field's start or end, Command+Left/Right to the start or end of the caret's own line (each when the goal is
    /// there or a short arrow run from there, on the near side), Option+Left/Right while the next word boundary is not
    /// past the goal. A hop that lands elsewhere is corrected from where it landed.
    /// Option+arrow only. Command+arrow is Back/Forward or a page scroll in browsers if focus ever slips off the
    /// field between the guard and the key, which could navigate away from the user's page.
    static let safeHops: Set<CaretHop> = [.wordLeft, .wordRight]

    private static func hop(from caret: Int, to goal: Int, in doc: Document, allowed: (CaretHop) -> Bool) -> (CaretHop, Int)? {
        let before = Array(doc.context(before: caret, 2_000).reversed())
        let after = Array(doc.context(after: caret, 2_000))
        func units(_ characters: ArraySlice<Character>) -> Int { characters.reduce(0) { $0 + String($1).utf16.count } }
        func word(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" || c == "_" }
        if goal < caret {
            let near = arrowRun
            if goal <= near, doc.string(0, goal)?.contains(where: \.isNewline) == false, allowed(.documentStart) { return (.documentStart, 0) }
            let toLine = before.firstIndex(where: \.isNewline) ?? before.count
            let lineStart = caret - units(before[..<toLine])
            if goal >= lineStart, goal - lineStart <= near, toLine < before.count || lineStart == 0, allowed(.lineStart) {
                return (.lineStart, lineStart)
            }
            var i = 0
            while i < before.count, !word(before[i]) { i += 1 }
            while i < before.count, word(before[i]) { i += 1 }
            let start = caret - units(before[..<i])
            if start >= goal, start < caret, allowed(.wordLeft) { return (.wordLeft, start) }
        } else if goal > caret {
            let contentEnd = doc.length - (doc.text.hasSuffix("\n\n") || doc.text as String == "\n" ? 1 : 0)
            let near = arrowRun
            if goal <= contentEnd, contentEnd - goal <= near, doc.base + doc.text.length == doc.length,
               doc.string(goal, contentEnd - goal)?.contains(where: \.isNewline) == false, allowed(.documentEnd) {
                return (.documentEnd, contentEnd)
            }
            let toLine = after.firstIndex(where: \.isNewline) ?? after.count
            let lineEnd = caret + units(after[..<toLine])
            if goal <= lineEnd, lineEnd - goal <= near, toLine < after.count, allowed(.lineEnd) { return (.lineEnd, lineEnd) }
            var i = 0
            while i < after.count, !word(after[i]) { i += 1 }
            while i < after.count, word(after[i]) { i += 1 }
            let end = caret + units(after[..<i])
            if end <= goal, end > caret, allowed(.wordRight) { return (.wordRight, end) }
        }
        return nil
    }

    /// Nothing else to do: the caret goes back to where the user expects it. Without a trusted caret set, arrows
    /// cannot rebuild a selection, so a selected range gets the caret at its end.
    private func restoreCaret(doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int) async -> Bool {
        guard let wanted = userCaret, wanted.end <= doc.length else { caretOwed = false; return false }
        let goal = UTF16Range(location: wanted.end, length: 0)
        if let stale = staleCaret, stale.reported == selection {
            staleCaret = nil
            if await settle(before: .move) { return true }
            return await refresh(stale.believed, doc: doc, selection: selection, target: target, mark: mark, region: nil)
        }
        // A caret set the field reported but never proved is proved before the caret counts as back.
        if probeAt == selection.location, selection.length == 0, caretJumps.direct == .tentative {
            if await settle(before: .move) { return true }
            return await probe(doc: doc, selection: selection, target: target, mark: mark, region: nil)
        }
        if selection == wanted || selection == goal {
            caretOwed = false
            userCaret = selection
            return true
        }
        let full = caretJumps.direct == .trusted ? wanted : goal
        return await move(toward: full, doc: doc, selection: selection, target: target, mark: mark, region: nil)
    }

    /// At a transition between moves and edits the last key gets `keySettle` to land before the next is planned.
    private func settle(before kind: KeyKind) async -> Bool {
        guard let last = lastKey, last.kind != kind else { return false }
        // Accessibility/key observation already proved this move. No guessed delay is needed before an edit;
        // tentative caret sets and late/off-target moves retain their existing proof and transit barriers.
        if last.kind == .move, kind == .edit, lastMoveConfirmed { return false }
        let elapsed = now() - last.at
        guard elapsed < Self.keySettle else { return false }
        await sleep(Self.keySettle - elapsed)
        lastKey = (kind == .move ? .edit : .move, now() - Self.keySettle)
        return true
    }

    /// Sends one key through the target's guards. A refusal sends nothing: the next step reads again and replans.
    private func sendKey(_ key: FieldKey, target: any TextTarget, mark: Int, selection: UTF16Range) -> FieldKeyRefusal? {
        let kind: FieldEditCoordinator.Operations.Kind
        switch key { case .backspace, .text: kind = .edit; default: kind = .move }
        guard beginOperation(kind, transit: Self.keyLateLimit) else { return .unavailable }
        do {
            try target.press(key, mark: mark, selection: selection)
            operationDispatched()
            opsSent += 1
            return nil
        } catch {
            operations.invalidate() // a refused key was never dispatched
            let refusal = error as? FieldKeyRefusal ?? .unavailable
            note(.refused, reason: "\(refusal)")
            refused(refusal, target: target, mark: mark)
            return refusal
        }
    }

    private func refused(_ refusal: FieldKeyRefusal, target: any TextTarget, mark: Int) {
        switch refusal {
        case .modifiersHeld: holding = true
        case .userInput: userActedFlag = true
        // A selection that moved with no real input while a key of ours may still land is that key's, not the user's.
        case .selectionMoved: if target.inputMark != mark || lateKey == nil { userActedFlag = true }
        case .notFocused, .unavailable: break
        }
    }

    /// Reads back until `check` holds, up to `limit`.
    private func poll(_ limit: Duration, _ check: () -> Bool) async -> Bool {
        let start = now()
        while !check() {
            if now() - start >= limit { return false }
            await sleep(Self.keyPoll)
        }
        return true
    }

    /// Graphemes still to type outside `region`: other regions' growth and words waiting for a region.
    private func typedBacklog(besides region: Region) -> Int {
        allRegions.reduce(0) { $0 + ($1 === region || $1.lost ? 0 : max(0, $1.desired.count - $1.current.count)) }
            + runs.reduce(0) { $0 + $1.remainder.count }
    }

    /// The region's text became `landed` (an op of ours): other regions and the user's caret after it shift.
    private func apply(_ region: Region, landed: [Character], at range: UTF16Range? = nil, delta explicit: Int? = nil, inserted: Int = 0) {
        let delta = explicit ?? (String(landed).utf16.count - String(region.current).utf16.count)
        let pivot = range?.location ?? region.start
        let pivotEnd = range.map { $0.location + $0.length } ?? region.end
        let oldEnd = region.end
        if region.current != landed { region.verifiedWrites += 1 }
        region.uncertainWrite = false
        if let plan = region.nativePlan, plan.expected != landed { region.nativePlan = nil }
        region.current = landed
        region.failures = 0
        // Regions after this one shift; one that overlaps it (a run region under a Magic edit) keeps its place and is
        // found again, or not, on the next read.
        if delta != 0 {
            for other in allRegions where other !== region && other.start >= pivotEnd && other.start >= oldEnd { other.start += delta }
        }
        if let caret = userCaret, caret.location >= pivotEnd, !(region.open && caret.location == pivotEnd) {
            userCaret = UTF16Range(location: caret.location + delta, length: caret.length)
        } else if let caret = userCaret, caret.location + caret.length > pivot, caret.location < pivotEnd {
            // The user's caret or selection overlapped the changed characters: it goes after the new ones.
            userCaret = UTF16Range(location: pivot + inserted, length: 0)
        }
    }

    private func nativeWriteUnchanged(_ region: Region, doc: Document, target: any TextTarget) -> Bool {
        (try? target.textLength()) == doc.length
            && (try? target.text(in: UTF16Range(location: region.start, length: String(region.current).utf16.count))) == String(region.current)
    }

    private func failed(_ region: Region, after: [Character], reason: String, unchanged: Bool = false) async -> Bool {
        region.nativePlan = nil
        if unchanged { region.uncertainWrite = false }
        region.failures += 1
        region.landing = unchanged ? region.current : after
        note(.mismatch, id: region.id, run: region.runID, reason: reason, detail: "failures=\(region.failures)")
        if region.failures >= Self.retryLimit {
            if unchanged, !reassessedWriteFailure, let target, target.editsInPlace, target.isFocused() {
                reassessedWriteFailure = true
                if target.recoverWriteFailure() {
                    // Nothing of this op landed. The next queue step reads again and plans the missing changes
                    // through the reassessed transport; already confirmed text is never replayed.
                    region.failures = 0
                    region.landing = nil
                    expectedSelections = []
                    return true
                }
            }
            region.lost = true
            drop(region, .failed)
        }
        // Give a slow field time to show the op before the next read decides whether it landed.
        await sleep(Self.waitTick)
        return true
    }

    // MARK: Runs

    /// The run's newest text is split over its regions by the minimal diff from what they stand for; text past the last
    /// region goes to the open region, or waits for a new one.
    private func retarget(_ run: inout Run, to text: [Character]) {
        run.target = text
        let sources = run.regions.map(\.source)
        let old = sources.flatMap { $0 } + run.remainder
        let changes = FieldEditCoordinator.changes(from: old, to: text)
        // Text inserted at a boundary between regions belongs to the earlier one; at the run's closed end it waits for a
        // region at the user's caret (`inclusive` false).
        func map(_ boundary: Int, inclusive: Bool = true) -> Int {
            var shift = 0
            for change in changes {
                if change.end < boundary || (change.end == boundary && change.start < boundary)
                    || (inclusive && change.start == boundary && change.end == boundary) {
                    shift += change.text.count - (change.end - change.start)
                } else if change.start < boundary, boundary < change.end {
                    return change.start + shift + change.text.count
                } else { break }
            }
            return boundary + shift
        }
        var lower = 0, cursor = 0
        for (index, region) in run.regions.enumerated() {
            cursor += sources[index].count
            let last = index == run.regions.count - 1
            var upper = last && region.open ? text.count : min(text.count, max(lower, map(cursor, inclusive: !last)))
            // A word the user's key or click cut short is finished in its region first.
            if last, !region.open, !region.lost, upper > lower, !text[upper - 1].isWhitespace {
                while upper < text.count, !text[upper].isWhitespace { upper += 1 }
            }
            let slice = Array(text[lower..<upper])
            region.source = slice
            if !region.lost {
                region.desired = region.separator + (region.trimsLead ? Array(slice.drop { $0.isWhitespace && !$0.isNewline }) : slice)
            }
            lower = upper
        }
        run.remainder = lower < text.count ? Array(text[lower...]) : []
        if run.regions.last?.open == true { run.remainder = [] }
    }

    private func close(_ run: inout Run, cause: String) {
        for region in run.regions where region.open {
            region.open = false
            note(.regionClosed, id: region.id, run: run.id, reason: cause)
        }
    }

    // MARK: Drops

    private func drop(_ region: Region, _ reason: Reason) {
        let represented = region.landing ?? region.current
        let appending = region.desired.starts(with: represented)
        if reason == .failed, appending, region.runID != nil, let onUnreadable {
            // A readable field may acknowledge writes without applying them. Keep the take growing in the panel,
            // exactly as when reads stop, rather than abandoning all its later snapshots.
            region.lost = false
            onUnreadable(handOver())
            return
        }
        region.dropReason = reason
        note(.dropped, id: region.id, run: region.runID, text: String(region.desired), reason: reason.rawValue)
        let typed = reason == .userChanged || !appending ? 0 : represented.count
        onDrop?(Drop(id: region.id, runID: region.runID, reason: reason, text: String(region.desired), typed: typed))
        region.desired = region.current
    }

    private func dropAll(_ reason: Reason) {
        caretOwed = false
        for pending in edits {
            onDrop?(Drop(id: pending.edit.id, runID: nil, reason: reason, text: pending.edit.target))
            pending.done.resume(returning: .dropped(reason))
        }
        edits = []
        for entry in editRegions {
            if entry.region.pending { drop(entry.region, reason) }
            entry.done.resume(returning: stoppedResult(entry.region, reason: reason))
        }
        editRegions = []
        for index in runs.indices { abandon(index, reason) }
    }

    /// A run whose field went away drops once, as a whole: its newest text goes to the owner for panel recovery,
    /// and its later versions are neither placed nor dropped again. A run with nothing left to place stays as it is.
    private func abandon(_ index: Int, _ reason: Reason) {
        guard !runs[index].abandoned, runs[index].regions.contains(where: \.pending) || runs[index].needsRegion else { return }
        let onlyAppending = runs[index].regions.filter(\.pending).allSatisfy { $0.desired.starts(with: $0.landing ?? $0.current) }
        let typed = onlyAppending && !runs[index].speechTarget.hasDeferredRevision ? Self.typedCount(runs[index].regions.map {
            TypedRegion(current: $0.landing ?? $0.current, desired: $0.desired, source: $0.source, separator: $0.separator,
                        original: Array($0.original), trimsLead: $0.trimsLead, lost: $0.lost)
        }) : 0
        for region in runs[index].regions {
            if region.pending { region.dropReason = reason; region.desired = region.current }
            region.open = false
        }
        runs[index].remainder = []
        runs[index].abandoned = true
        // A retracted run's text is not wanted: nothing to recover.
        let text = runs[index].retracted ? "" : String(runs[index].speechTarget.authoritative)
        note(.dropped, run: runs[index].id, text: text, reason: reason.rawValue)
        onDrop?(Drop(id: runs[index].id, runID: runs[index].id, reason: reason, text: text, typed: typed))
    }

    // MARK: Panel handover

    /// A run with words still to place that was neither given up nor handed over.
    private func handable(_ index: Int) -> Bool {
        !runs[index].abandoned && !runs[index].retracted && (runs[index].regions.contains(where: \.pending) || runs[index].needsRegion)
    }

    /// The field stopped reading: every run with words left goes on in the panel. What it typed stays as it is, nothing
    /// is dropped, and its later versions are the panel's (`abandoned`, without a drop).
    private func handOver() -> [Handover] {
        var handovers: [Handover] = []
        for index in runs.indices where handable(index) {
            let requiresReview = runs[index].speechTarget.hasDeferredRevision
                || runs[index].regions.filter(\.pending).contains(where: { !$0.desired.starts(with: $0.landing ?? $0.current) })
            // A key that went out but did not read back usually landed: it counts as typed, so it is not typed twice.
            let typed = Self.typedCount(runs[index].regions.map {
                TypedRegion(current: $0.landing ?? $0.current, desired: $0.desired, source: $0.source, separator: $0.separator,
                            original: Array($0.original), trimsLead: $0.trimsLead, lost: $0.lost)
            })
            for region in runs[index].regions {
                if region.pending { region.desired = region.current }
                region.open = false
            }
            runs[index].remainder = []
            runs[index].abandoned = true
            let run = runs[index]
            note(.panel, run: run.id, length: typed, text: String(run.speechTarget.authoritative), reason: "unreadable")
            handovers.append(Handover(runID: run.id, version: run.version, text: String(run.speechTarget.authoritative), typed: typed,
                                      complete: run.complete, requiresReview: requiresReview))
        }
        return handovers
    }

    /// What `typedCount` needs of a region.
    struct TypedRegion {
        var current: [Character], desired: [Character], source: [Character], separator: [Character], original: [Character]
        var trimsLead = false, lost = false
    }

    /// How many characters of a run's text the field shows: up to the end of what its last region with typed text stands
    /// for. A dropped region counts whole (it was reported already).
    static func typedCount(_ regions: [TypedRegion]) -> Int {
        var covered = 0, typed = 0
        for region in regions {
            defer { covered += region.source.count }
            if region.lost { typed = covered + region.source.count; continue }
            // Nothing of the run's own went in yet: the region still shows the selection it replaces.
            if !region.original.isEmpty, region.current == region.original { continue }
            let lead = region.trimsLead ? region.source.prefix { $0.isWhitespace && !$0.isNewline }.count : 0
            guard region.current.starts(with: region.separator), region.desired.starts(with: region.separator) else { continue }
            let body = Array(region.current.dropFirst(region.separator.count))
            let shown = body.isEmpty ? 0 : typedPrefix(current: body, desired: Array(region.desired.dropFirst(region.separator.count)))
            if shown > 0 || (!region.separator.isEmpty && lead > 0) { typed = covered + min(region.source.count, lead + shown) }
        }
        return typed
    }

    /// How many characters of `desired` the field's `current` stands for. Usually `current` is the start of `desired`; where
    /// a revision changed words already typed, those words stay and stand for as many words of `desired`.
    static func typedPrefix(current: [Character], desired: [Character]) -> Int {
        var common = 0
        while common < current.count, common < desired.count, current[common] == desired[common] { common += 1 }
        if common == current.count { return common }
        let words = current.split(whereSeparator: \.isWhitespace)
        var index = 0, seen = 0
        while index < desired.count, seen < words.count {
            while index < desired.count, desired[index].isWhitespace { index += 1 }
            guard index < desired.count else { break }
            seen += 1
            let start = index
            while index < desired.count, !desired[index].isWhitespace { index += 1 }
            // A word typed part-way that the newest one goes on from (a capital or a stop added) stands for its start.
            if seen == words.count, let last = words.last, current.last?.isWhitespace == false,
               String(desired[start..<index]).lowercased().hasPrefix(String(last).lowercased()) {
                return start + last.count
            }
        }
        if current.last?.isWhitespace == true, index < desired.count, desired[index].isWhitespace { index += 1 }
        return index
    }

    // MARK: Journal

    private func note(_ kind: MacEditJournal.Kind, id: String? = nil, run: String? = nil, location: Int? = nil, length: Int? = nil,
                      text: String? = nil, read: String? = nil, selection: UTF16Range? = nil, reason: String? = nil, detail: String? = nil) {
        guard let journal else { return }
        var entry = MacEditJournal.Entry(kind: kind, field: documentID)
        entry.id = id; entry.run = run; entry.location = location; entry.length = length; entry.text = text; entry.read = read
        entry.selection = selection.map { "\($0.location)+\($0.length)" }; entry.reason = reason; entry.detail = detail ?? (kind == .verified ? debugState : nil)
        journal(entry)
    }
}

/// What a keystroke field showed about moving its caret, remembered per field (`TextTarget.fieldKey`) across bindings.
public struct CaretJumps: Sendable, Equatable {
    public enum Direct: String, Sendable, Equatable {
        /// Never tried.
        case untested
        /// An Accessibility caret set read back, but no arrow proved yet that the real caret followed it.
        case tentative
        /// The field takes caret sets: jumps go straight there.
        case trusted
        /// A set did not read back, or the real caret did not follow it: hops and arrows only.
        case refused
    }
    public var direct: Direct = .untested
    /// Hops that landed where predicted and that did not; a hop the field refused, or that keeps missing, is not used.
    public var hits: [CaretHop: Int] = [:]
    public var misses: [CaretHop: Int] = [:]
    public var unsupported: Set<CaretHop> = []
    public init() {}
    public func allows(_ hop: CaretHop) -> Bool {
        let missed = misses[hop, default: 0]
        return !unsupported.contains(hop) && (missed < 3 || hits[hop, default: 0] >= 2 * missed)
    }
    /// What a jump costs the planner here: one caret set where it is trusted, else a few hops and arrows.
    public var jumpMs: Double { direct == .trusted ? KeystrokePlanner.keyMs : KeystrokePlanner.jumpMs }
}
