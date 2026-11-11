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
///   is edited with synthetic keys, one key in flight, each confirmed by reading the text and selection back:
///   Left/Right arrows to move, Backspace to delete, one grapheme per Unicode key to type. `KeystrokePlanner` chooses
///   the keys (whole-word and merged spans, minimal or block per span, about `KeystrokePlanner.budgetMs` per change,
///   paced by the backlog). A key whose guard fails is not sent; the next step reads the field again and replans.
/// - Never freezes on the user: their typing and clicks are seen on the next read. Regions (the text a run or edit
///   owns) are found again at their place or uniquely elsewhere, and pending work is replanned there. A key or click
///   closes the open dictation region; later words start a new region at the user's caret, and revisions of closed
///   regions still land while their text is unchanged. Only work whose text the user changed, or that cannot be
///   placed, is dropped (`onDrop`); a field that loses focus waits up to `parkLimit`.
@MainActor
public final class MacFieldQueue {
    public enum Reason: String, Sendable, Equatable { case userChanged, cannotPlace, focusLost, cancelled, failed }
    public struct Drop: Sendable, Equatable {
        public var id: String
        public var runID: String?
        public var reason: Reason
        /// The text that did not reach the field (the whole desired text of the work).
        public var text: String
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
    }

    // MARK: Tunables

    /// Text found again away from its place must occur there once and be at least this long; shorter text needs its
    /// context to match too.
    public static let relocateMinimum = 4
    /// An edit's scope found away from where it was read must be at least this long when its context is gone.
    public static let relocateChars = 16
    public static let contextChars = 16
    /// How long work waits for an unfocused or unreadable field before it is dropped.
    public static let parkLimit = Duration.seconds(3)
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
    /// The pause at a transition between moves and edits.
    public static let keySettle = Duration.milliseconds(Int(KeystrokePlanner.settleMs))

    // MARK: Configuration

    public let documentID: String
    public let target: (any TextTarget)?
    /// Typewriter pacing (false with Reduce Motion: every change goes whole).
    public var paced: @MainActor () -> Bool = { true }
    public var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    public var now: @MainActor () -> ContinuousClock.Instant = { .now }
    public var journal: (@MainActor (MacEditJournal.Entry) -> Void)?
    public var onDrop: (@MainActor (Drop) -> Void)?
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
        var failures = 0
        /// An op that did not read back yet: if the field shows this next, the op landed late.
        var landing: [Character]?
        /// Keystroke fields: the planned keys toward `desired`.
        var keys: KeyUnit?
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
        /// Words past the last region wait for a region of their own (whitespace alone waits for more words).
        var needsRegion: Bool {
            !retracted && remainder.contains { !$0.isWhitespace || $0.isNewline }
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
    /// Keystroke fields: the caret is away from where the user expects it (a jump that still has to come back).
    private var caretOwed = false
    /// Keystroke fields: arrows that did not read back in a row.
    private var moveFailures = 0
    /// A modifier is held: the queue waits without counting toward `parkLimit` (a held push-to-talk key).
    private var holding = false
    /// Keystroke fields: a key that did not read back in time, and the selection it would leave.
    private var lateKey: (at: ContinuousClock.Instant, selection: UTF16Range)?
    /// Keystroke fields: the last input mark seen, and when the user's real input last showed.
    private var lastMark: Int?
    private var inputAt: ContinuousClock.Instant?

    // MARK: Inspection

    public var hasWork: Bool {
        caretOwed || edits.isEmpty == false || editRegions.contains { $0.region.pending }
            || runs.contains { run in run.needsRegion || run.regions.contains(where: \.pending) }
    }
    /// The last run region (text and range) when it ends at the user's caret: the dictation Magic may call "what I said".
    public var lastRegionAtCaret: (range: UTF16Range, text: String)? {
        guard let region = runs.last?.regions.last, !region.lost, let caret = userCaret, caret.length == 0, region.end == caret.location
        else { return nil }
        return (UTF16Range(location: region.start, length: region.end - region.start), String(region.current))
    }
    public var debugState: String {
        let regions = runs.flatMap(\.regions).map { "\($0.runID ?? $0.id)@\($0.start)[\(String($0.current))→\(String($0.desired))]\($0.open ? "o" : "")\($0.lost ? "x" : "")" }
        return "rev=\(revision) owed=\(caretOwed) caret=\(userCaret.map { "\($0.location)+\($0.length)" } ?? "-") edits=\(edits.count)+\(editRegions.count) regions=\(regions)"
    }

    // MARK: Enqueue

    /// A live run's newest text (a snapshot, a growing take, a typed line). Older versions of a run are ignored.
    public func live(runID: String, version: Int, text: String) {
        let index = runs.firstIndex { $0.id == runID } ?? {
            runs.append(Run(id: runID)); return runs.count - 1
        }()
        guard !runs[index].retracted, version > runs[index].version else { return }
        // A new run closes the open region of earlier runs: its words start where the user's caret is.
        if runs[index].regions.isEmpty, runs[index].version < 0 {
            for other in runs.indices where other != index { close(&runs[other], cause: "newRun") }
        }
        runs[index].version = version
        retarget(&runs[index], to: Array(text))
        note(.live, id: nil, run: runID, text: text, detail: "v\(version)")
        schedule()
    }

    /// Takes a run's text back out: the field shows what was there before it (its initial selection, if any).
    public func retract(runID: String) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].retracted = true
        runs[index].remainder = []
        for (offset, region) in runs[index].regions.enumerated() where !region.lost {
            region.retracting = true; region.open = false
            region.separator = []; region.source = []
            region.desired = offset == 0 ? Array(region.original) : []
        }
        note(.live, id: nil, run: runID, text: "", detail: "retract")
        schedule()
    }

    /// Lands an edit and returns once it was applied or dropped.
    public func edit(_ edit: Edit) async -> EditResult {
        guard target != nil else { return .dropped(.cannotPlace) }
        note(.edit, id: edit.id, text: edit.target, detail: "scope=\(edit.scope)")
        return await withCheckedContinuation { done in
            edits.append(PendingEdit(edit: edit, since: now(), done: done))
            schedule()
        }
    }

    /// Runs `body` (the panel's typed insert) once everything before it landed; nothing else goes out meanwhile.
    public func exclusive<T>(label: String, text: String, _ body: @MainActor () async -> T) async -> T {
        note(.typed, id: label, text: text)
        await whenIdle()
        exclusive = true
        defer { exclusive = false; schedule() }
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
        while hasWork, !exclusive {
            defer { finishEdits() }
            let sent = opsSent
            // Steps that only re-plan (no op) are bounded: past a few, the queue waits like a blocked field.
            if await step(), opsSent > sent || idleSteps < 8 {
                if opsSent > sent { idleSteps = 0; blockedSince = nil } else { idleSteps += 1 }
            } else if holding {
                // Keys wait for the user's modifier to come up; that is not a field that went away.
                idleSteps = 0; blockedSince = nil
                await sleep(Self.waitTick)
            } else {
                idleSteps = 0
                let started = blockedSince ?? now()
                blockedSince = started
                if now() - started >= Self.parkLimit { dropAll(.focusLost); break }
                await sleep(Self.waitTick)
            }
        }
        finishEdits()
        pump = nil
        if !hasWork { let waiters = idleWaiters; idleWaiters = []; waiters.forEach { $0.resume() } }
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

    private func read(_ target: any TextTarget) -> (Document, UTF16Range)? {
        guard let selection = try? target.selectedRange(), let length = try? target.textLength() else { return nil }
        var base = 0, count = length
        if length > Self.readCap {
            base = max(0, min(length - Self.readCap, selection.location - Self.readCap / 2))
            count = Self.readCap
        }
        guard let text = try? target.text(in: UTF16Range(location: base, length: count)) else { return nil }
        return (Document(base: base, text: text as NSString, length: length), selection)
    }

    /// One op at most. False when the field cannot take one now (unfocused, unreadable, an edit not yet placeable).
    private func step() async -> Bool {
        holding = false
        guard let target else { return false }
        // Real input after this mark refuses a key planned from this read.
        let mark = target.inputMark
        guard target.isFocused(), let (doc, selection) = read(target).map({ ($0.0, $0.1) }) else { return false }
        noteUser(selection: selection, doc: doc)
        locateAll(doc)
        placeEdits(doc)
        finishEdits()
        let keyed = !target.editsInPlace && target.typesKeys
        if keyed {
            if mark != lastMark { if lastMark != nil { inputAt = now() }; lastMark = mark }
            // The user is typing or clicking: keys wait until they rest (without counting toward `parkLimit`).
            if let input = inputAt, now() - input < Self.keyQuiet { holding = true; return false }
        }
        if keyed, let late = lateKey {
            // Never a second key while the last one may still land.
            if selection != late.selection, now() - late.at < Self.keyLateLimit { return false }
            lateKey = nil
        }
        if let region = nextRegion() {
            if keyed { return await performKey(region, doc: doc, selection: selection, target: target, mark: mark) }
            return await perform(region, doc: doc, target: target)
        }
        if openRemainderRegion(doc) { return true }
        if keyed, caretOwed { return await restoreCaret(doc: doc, selection: selection, target: target, mark: mark) }
        caretOwed = false
        return false
    }

    private func noteUser(selection: UTF16Range, doc: Document) {
        let moved = !expectedSelections.isEmpty && !expectedSelections.contains(selection)
        if userActedFlag || moved {
            userActedFlag = false
            userCaret = selection
            caretOwed = false
            revision += 1
            for index in runs.indices { close(&runs[index], cause: moved ? "cursor" : "input") }
            note(.user, selection: selection, detail: moved ? "moved" : "acted")
        }
        // A caret past the text (work that did not land after all) is the field's own caret again.
        if userCaret == nil || (userCaret.map { $0.location + $0.length > doc.length } ?? false) { userCaret = selection }
        // A key that may still land leaves its selection ours until it shows or its window passes.
        expectedSelections = [selection] + (lateKey.map { [$0.selection] } ?? [])
    }

    private var allRegions: [Region] { editRegions.map(\.region) + runs.flatMap(\.regions) }

    private func locateAll(_ doc: Document) {
        for region in allRegions where !region.lost { locate(region, doc) }
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
            if doc.string(region.start, landingLength) == String(landing), landing != region.current,
               doc.context(after: region.start + landingLength, Self.contextChars) == region.after {
                let follows = region.open && userCaret == UTF16Range(location: region.end, length: 0)
                apply(region, landed: landing)
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
            refreshContext(region, doc)
            return
        }
        region.lost = true
        // An empty run region is placed again (`locateAll`); anything else was changed under it.
        if region.runID != nil, region.current.isEmpty, region.original.isEmpty { return }
        if region.current != region.desired { drop(region, .userChanged) }
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
    }

    private func placeEdits(_ doc: Document) {
        var waiting: [PendingEdit] = []
        for pending in edits {
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

    private func finishEdits() {
        editRegions.removeAll { entry in
            if entry.region.lost { entry.done.resume(returning: .dropped(entry.region.dropReason)); return true }
            guard !entry.region.pending else { return false }
            let range = UTF16Range(location: entry.region.start, length: entry.region.end - entry.region.start)
            note(.applied, id: entry.region.id, location: range.location, length: range.length)
            entry.done.resume(returning: .applied(range))
            return true
        }
    }

    /// Edits first (the user is waiting on Magic), then dictation in speaking order.
    private func nextRegion() -> Region? {
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

    private func perform(_ region: Region, doc: Document, target: any TextTarget) async -> Bool {
        let changes = ShadowEditPlanner.changes(from: region.current, to: region.desired)
        guard let change = changes.first else { return true }
        let whole = !pacedNow
        var lower = change.start, upper = change.end, insertion: [Character] = []
        if whole {
            insertion = change.text
        } else if upper > lower {
            lower = upper - 1 // one grapheme at a time, from the end of the deleted span
        } else {
            insertion = [change.text[0]]
        }
        let location = region.start + String(region.current[..<lower]).utf16.count
        let removed = String(region.current[lower..<upper])
        let range = UTF16Range(location: location, length: removed.utf16.count)
        let text = String(insertion)
        // The caret follows an open region's end when the user's caret was there.
        let follows = region.open && userCaret == UTF16Range(location: region.end, length: 0)
        var after = region.current
        after.replaceSubrange(lower..<upper, with: insertion)
        note(.sent, id: region.id, run: region.runID, location: range.location, length: range.length, text: text,
             read: doc.context(before: range.location, 40) + "|" + doc.context(after: range.location, 40))
        opsSent += 1
        do {
            try target.replace(range, with: text)
        } catch {
            expectedSelections.append(UTF16Range(location: range.location + text.utf16.count, length: 0))
            return await failed(region, after: after, reason: "write")
        }
        // Read back the region and the caret before anything else goes out.
        let shown = try? target.text(in: UTF16Range(location: region.start, length: String(after).utf16.count))
        guard shown == String(after) else {
            // The op may still land: the caret it leaves is ours too.
            expectedSelections.append(UTF16Range(location: range.location + text.utf16.count, length: 0))
            return await failed(region, after: after, reason: "readback")
        }
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
        if selection != wanted {
            try? target.setSelectedRange(wanted)
            expectedSelections = [(try? target.selectedRange()) == wanted ? wanted : (selection ?? wanted)]
        } else {
            expectedSelections = [wanted]
        }
        note(.verified, id: region.id, run: region.runID, location: region.start, length: region.end - region.start, text: String(region.current),
             selection: wanted)
        if pacedNow, !insertion.isEmpty {
            let remaining = ShadowEditPlanner.changes(from: region.current, to: region.desired).reduce(0) { $0 + $1.text.count }
            await sleep(TypewriterPlan.interval(steps: remaining + 2))
        }
        return true
    }

    // MARK: Keystrokes

    /// The region's planned keys, kept while the region's text follows them (a key that read back late moves the unit
    /// on); planned again when the desired text changed or the field shows anything else.
    private func keyUnit(for region: Region) -> KeyUnit? {
        if let unit = region.keys, unit.desired == region.desired {
            for index in unit.index..<min(unit.steps.count, unit.index + 4) where unit.steps[index].before == region.current {
                unit.index = index
                return unit
            }
        }
        let typedMs = pacedNow ? KeystrokePlanner.calmMs : KeystrokePlanner.keyMs
        let steps = KeystrokePlanner.steps(from: region.current, to: region.desired, paceMs: typedMs)
        guard !steps.isEmpty else { region.keys = nil; return nil }
        let typed = steps.reduce(0) { if case .type = $1.key { $0 + 1 } else { $0 } }
        let fixed = Double(steps.count - typed) * KeystrokePlanner.keyMs
        let unit = KeyUnit(desired: region.desired, steps: steps, paceMs: KeystrokePlanner.paceMs(ops: typed, fixedMs: fixed))
        region.keys = unit
        note(.planned, id: region.id, run: region.runID, location: region.start, text: String(region.desired),
             detail: "keys=\(steps.count) typed=\(typed) pace=\(Int(unit.paceMs))")
        return unit
    }

    /// One key toward the region's desired text: an arrow while the caret is not where the next edit goes, else the
    /// edit (Backspace or one grapheme). It is confirmed by reading the region's text, the length and the selection.
    private func performKey(_ region: Region, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int) async -> Bool {
        guard let unit = keyUnit(for: region) else { return true }
        let step = unit.steps[unit.index]
        let caret = region.start + String(step.before[..<step.caret]).utf16.count
        guard selection == UTF16Range(location: caret, length: 0) else {
            return await move(toward: caret, doc: doc, selection: selection, target: target, mark: mark, region: region)
        }
        if await settle(before: .edit) { return true }
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
             read: doc.context(before: range.location, 40) + "|" + doc.context(after: range.location, 40), detail: "key")
        guard send(key, target: target, mark: mark, selection: selection) else { return false }
        let sentAt = now()
        lastKey = (.edit, sentAt)
        let delta = inserted.utf16.count - range.length
        let expected = UTF16Range(location: range.location + inserted.utf16.count, length: 0)
        let window = UTF16Range(location: region.start, length: String(after).utf16.count)
        let landed = await poll {
            (try? target.selectedRange()) == expected && (try? target.textLength()) == doc.length + delta
                && (try? target.text(in: window)) == String(after)
        }
        guard landed else {
            expectedSelections.append(expected)
            if target.inputMark != mark {
                // The user typed or clicked meanwhile: not the key's failure. The next read takes their input and
                // finds the key's text where it landed.
                region.landing = after
                userActedFlag = true
                note(.mismatch, id: region.id, run: region.runID, reason: "user", detail: "failures=\(region.failures)")
                return true
            }
            // The key may still land: its caret is ours too, and the next read takes its text as landed late.
            lateKey = (sentAt, expected)
            return await failed(region, after: after, reason: "key")
        }
        apply(region, landed: after, at: range, delta: delta, inserted: inserted.utf16.count)
        unit.index += 1
        revision += 1
        if follows || (region.current == region.desired && region.caretAfter) { userCaret = UTF16Range(location: region.end, length: 0) }
        expectedSelections = [expected]
        caretOwed = userCaret != expected
        note(.verified, id: region.id, run: region.runID, location: region.start, length: region.end - region.start,
             text: String(region.current), selection: expected)
        if case .type = step.key, pacedNow {
            // The faster of the change's own pace and the backlog's, counted from when the key went out.
            let pace = min(unit.paceMs, KeystrokePlanner.paceMs(ops: unit.typedLeft + typedBacklog(besides: region)))
            let gap = Duration.milliseconds(pace) - (now() - sentAt)
            if gap > .zero { await sleep(gap) }
        }
        return true
    }

    /// One arrow toward `goal`: Left or Right without modifiers (with a selection, the arrow collapses it).
    private func move(toward goal: Int, doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int,
                      region: Region?) async -> Bool {
        if await settle(before: .move) { return true }
        let key: FieldKey
        let exact: UTF16Range
        if selection.length > 0 {
            key = goal <= selection.location ? .left : .right
            exact = UTF16Range(location: key == .left ? selection.location : selection.end, length: 0)
        } else if goal < selection.location {
            key = .left
            let size = doc.context(before: selection.location, 32).last.map { String($0).utf16.count } ?? 1
            exact = UTF16Range(location: selection.location - size, length: 0)
        } else {
            key = .right
            let size = doc.context(after: selection.location, 32).first.map { String($0).utf16.count } ?? 1
            exact = UTF16Range(location: selection.location + size, length: 0)
        }
        note(.sent, id: region?.id, run: region?.runID, location: selection.location, selection: exact,
             detail: key == .left ? "left" : "right")
        guard send(key, target: target, mark: mark, selection: selection) else { return false }
        let sentAt = now()
        lastKey = (.move, sentAt)
        var seen: UTF16Range?
        let moved = await poll {
            guard let now = try? target.selectedRange(), now != selection, (try? target.textLength()) == doc.length else { return false }
            // The host's grapheme boundary may differ from ours: a collapsed caret one step the right way counts.
            let ok = now == exact || (now.length == 0 && selection.length == 0
                                      && (key == .left ? now.location < selection.location : now.location > selection.location))
            if ok { seen = now }
            return ok
        }
        guard moved, let seen else {
            expectedSelections.append(exact)
            if target.inputMark != mark {
                // The user typed or clicked meanwhile: the next read takes their caret.
                userActedFlag = true
                return true
            }
            lateKey = (sentAt, exact)
            moveFailures += 1
            note(.mismatch, id: region?.id, run: region?.runID, reason: "move", detail: "failures=\(moveFailures)")
            if moveFailures >= Self.retryLimit {
                moveFailures = 0
                if let region { region.lost = true; drop(region, .failed) } else { caretOwed = false }
            }
            await sleep(Self.waitTick)
            return true
        }
        moveFailures = 0
        expectedSelections = [seen]
        caretOwed = userCaret != seen
        return true
    }

    /// Nothing else to do: the caret goes back to where the user expects it. Plain arrows cannot rebuild a selection,
    /// so a selected range gets the caret at its end.
    private func restoreCaret(doc: Document, selection: UTF16Range, target: any TextTarget, mark: Int) async -> Bool {
        guard let wanted = userCaret, wanted.end <= doc.length else { caretOwed = false; return false }
        let goal = UTF16Range(location: wanted.end, length: 0)
        if selection == wanted || selection == goal {
            caretOwed = false
            userCaret = selection
            return true
        }
        return await move(toward: goal.location, doc: doc, selection: selection, target: target, mark: mark, region: nil)
    }

    /// At a transition between moves and edits the last key gets `keySettle` to land before the next is planned.
    private func settle(before kind: KeyKind) async -> Bool {
        guard let last = lastKey, last.kind != kind else { return false }
        let elapsed = now() - last.at
        guard elapsed < Self.keySettle else { return false }
        await sleep(Self.keySettle - elapsed)
        lastKey = (kind == .move ? .edit : .move, now() - Self.keySettle)
        return true
    }

    /// Sends one key through the target's guards. A refusal sends nothing: the next step reads again and replans.
    private func send(_ key: FieldKey, target: any TextTarget, mark: Int, selection: UTF16Range) -> Bool {
        do {
            try target.press(key, mark: mark, selection: selection)
            opsSent += 1
            return true
        } catch {
            let refusal = error as? FieldKeyRefusal ?? .unavailable
            note(.refused, reason: "\(refusal)")
            switch refusal {
            case .modifiersHeld: holding = true
            case .userInput, .selectionMoved: userActedFlag = true
            case .notFocused, .unavailable: break
            }
            return false
        }
    }

    /// Reads back until `check` holds, up to `keyConfirm`.
    private func poll(_ check: () -> Bool) async -> Bool {
        let start = now()
        while !check() {
            if now() - start >= Self.keyConfirm { return false }
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

    private func failed(_ region: Region, after: [Character], reason: String) async -> Bool {
        region.failures += 1
        region.landing = after
        note(.mismatch, id: region.id, run: region.runID, reason: reason, detail: "failures=\(region.failures)")
        if region.failures >= Self.retryLimit {
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
        let changes = ShadowEditPlanner.changes(from: old, to: text)
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
            if last, !region.open, upper > lower, !text[upper - 1].isWhitespace {
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
        region.dropReason = reason
        note(.dropped, id: region.id, run: region.runID, text: String(region.desired), reason: reason.rawValue)
        onDrop?(Drop(id: region.id, runID: region.runID, reason: reason, text: String(region.desired)))
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
            entry.done.resume(returning: .dropped(reason))
        }
        editRegions = []
        for index in runs.indices {
            for region in runs[index].regions where region.pending { drop(region, reason) }
            if !runs[index].remainder.isEmpty {
                let text = String(runs[index].remainder)
                note(.dropped, run: runs[index].id, text: text, reason: reason.rawValue)
                onDrop?(Drop(id: runs[index].id, runID: runs[index].id, reason: reason, text: text))
                runs[index].remainder = []
            }
        }
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
