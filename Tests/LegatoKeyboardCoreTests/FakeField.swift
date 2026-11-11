import Foundation
@testable import LegatoKeyboardCore

/// A text field that misbehaves like real hosts: late reports, a short window around the cursor, Safari's block echo
/// (`"\n "` where a window starts at a block), emoji that move as one unit, and optionally a page that puts its caret
/// back after a move.
struct FakeField {
    var text: [Character]
    var caret: Int
    var selection = 0
    /// Reports show the field as it was this many ticks ago.
    var lagTicks = 0
    /// Characters around the cursor a report shows.
    var window = 60
    /// Windows stop at a line break and begin with "\n " there.
    var blockEcho = false
    /// A move of one unit crosses a whole emoji (Safari); otherwise moves count UTF-16 units.
    var movesByCharacters = false
    /// The page puts the caret back where it was a tick after a move.
    var caretResets = false
    private var history: [FieldQueue.Report] = []
    private var pendingReset: Int?

    /// Who wrote each character, and who deleted what: the stress test's provenance checks.
    enum Origin: String { case initial, outside, user, live, edit }
    var origin: [Origin]
    /// Who the next op is from.
    var writer = Origin.outside
    var deletions: [(char: Character, origin: Origin, by: Origin, racing: Bool)] = []
    /// The next op races with an outside action the queue has not seen yet.
    var racing = false
    /// Where the user's caret is: taps and the user's moves put it there; edits before it shift it.
    var userCaret: Int

    init(_ text: String = "", caret: Int? = nil) {
        self.text = Array(text)
        self.caret = caret ?? self.text.count
        origin = Array(repeating: .initial, count: self.text.count)
        userCaret = self.caret
    }

    var string: String { String(text) }

    /// The report as the field shows it now.
    var current: FieldQueue.Report {
        var start = max(0, caret - window)
        var prefix = ""
        if blockEcho, let breakIndex = text[start..<caret].lastIndex(where: \.isNewline) {
            start = breakIndex + 1
            prefix = "\n "
        }
        let before = prefix + String(text[start..<caret])
        let selected = selection > 0 ? String(text[caret..<(caret + selection)]) : nil
        let afterStart = caret + selection
        let after = String(text[afterStart..<min(text.count, afterStart + window)])
        return .init(before: before, after: after, selected: selected)
    }

    /// One host turn: returns the (possibly late) report.
    mutating func tick() -> FieldQueue.Report {
        if let back = pendingReset { caret = back; pendingReset = nil }
        history.append(current)
        if history.count > lagTicks + 1 { history.removeFirst(history.count - lagTicks - 1) }
        return history.first!
    }

    mutating func apply(_ op: ShadowOp) {
        switch op {
        case .move(let units):
            let from = caret
            if selection > 0 { if units >= 0 { caret += selection }; selection = 0 }
            var remaining = abs(units)
            while remaining > 0 {
                if units > 0 {
                    guard caret < text.count else { break }
                    remaining -= movesByCharacters ? 1 : String(text[caret]).utf16.count
                    caret += 1
                } else {
                    guard caret > 0 else { break }
                    remaining -= movesByCharacters ? 1 : String(text[caret - 1]).utf16.count
                    caret -= 1
                }
            }
            if caretResets, units != 0 { pendingReset = from }
            if writer == .user { userCaret = caret }
        case .deleteBackward(let count):
            for _ in 0..<count {
                if selection > 0 { remove(caret..<(caret + selection)); selection = 0; continue }
                guard caret > 0 else { break }
                remove((caret - 1)..<caret); caret -= 1
            }
        case .insert(let string):
            if selection > 0 { remove(caret..<(caret + selection)); selection = 0 }
            let chars = Array(string)
            text.insert(contentsOf: chars, at: caret)
            origin.insert(contentsOf: Array(repeating: writer, count: chars.count), at: caret)
            if userCaret >= caret { userCaret += chars.count }
            caret += chars.count
        }
    }

    private mutating func remove(_ range: Range<Int>) {
        for i in range { deletions.append((text[i], origin[i], writer, racing)) }
        text.removeSubrange(range); origin.removeSubrange(range)
        if userCaret >= range.upperBound { userCaret -= range.count } else if userCaret > range.lowerBound { userCaret = range.lowerBound }
    }

    /// The user taps somewhere (outside the keyboard).
    mutating func tap(at index: Int) { caret = max(0, min(text.count, index)); selection = 0; userCaret = caret }
    mutating func select(_ range: Range<Int>) { caret = range.lowerBound; selection = range.count; userCaret = caret }
    /// Another keyboard (a hardware keyboard) types: invisible to the queue except through reports.
    mutating func typeOutside(_ string: String) {
        let previous = writer; writer = .outside
        apply(.insert(string))
        writer = previous
    }
}

/// The keyboard's loop in miniature: steps the queue against a `FakeField` every `tickMs`.
struct QueueRig {
    var queue: FieldQueue
    var field: FakeField
    var tickMs = 33.0
    var clockMs = 0.0
    var sent: [(ms: Double, op: ShadowOp)] = []
    var events: [(ms: Double, event: FieldQueue.Event)] = []
    var lastLane: FieldQueue.Lane?
    /// For every user insert: the field's caret and where the user's caret was when it went out.
    var userInsertCarets: [(ms: Double, caret: Int, userCaret: Int, racing: Bool)] = []
    /// The user acted outside the keyboard (tap, selection, another keyboard) and the queue has not resynced since.
    var outsidePending = false

    /// Prints every step (`LEGATO_STRESS_TRACE=1`).
    var trace = ProcessInfo.processInfo.environment["LEGATO_STRESS_TRACE"] == "1"

    init(_ field: FakeField, config: FieldQueue.Config = .init(animated: false)) {
        self.field = field
        var config = config
        config.movesByCharacters = field.movesByCharacters
        queue = FieldQueue(config: config)
    }

    /// One tick: the host reports, the queue steps (and keeps stepping while the field confirms at once, like the
    /// keyboard's loop does for a synchronous host).
    mutating func tick() {
        clockMs += tickMs
        var elapsed = tickMs
        for _ in 0..<64 {
            let report = field.tick()
            let action = queue.step(report: report, elapsedMs: elapsed)
            elapsed = 0
            var syncUserCaret = false
            var behind = false
            for event in queue.drainEvents() {
                events.append((clockMs, event))
                if case .sent(_, let lane) = event { lastLane = lane }
                if event == .insertedBehind { behind = true }
                // A tap the late report had not shown yet races with the queue's own moves: once the queue sees the
                // change, where it puts the user's caret is the user's caret.
                if outsidePending, case .resync(let kind) = event, kind == .cursorMoved || kind == .reseeded {
                    outsidePending = false; syncUserCaret = true
                }
            }
            if trace {
                print(String(format: "%7.0f", clockMs), "report", report.before.suffix(24).debugDescription, "|", report.after.prefix(12).debugDescription,
                      report.selected.map { "sel=\($0.debugDescription)" } ?? "", "->", action,
                      events.suffix(4).map { "\($0.event)" }.joined(separator: " "))
                print("        field", field.string.debugDescription, "caret", field.caret, "user", field.userCaret,
                      "model", queue.modelText.debugDescription, "cursor", queue.cursor, "user", queue.userCursor, queue.debugState)
            }
            guard case .send(let op) = action else {
                if syncUserCaret { field.userCaret = field.caret + queue.userCursor - queue.cursor }
                break
            }
            sent.append((clockMs, op))
            if syncUserCaret, case .insert = op, lastLane == .user { field.userCaret = field.caret }
            field.writer = lastLane.map { lane in lane == .user ? .user : lane == .live ? .live : .edit } ?? .edit
            if case .insert = op, lastLane == .user { userInsertCarets.append((clockMs, field.caret, field.userCaret, outsidePending)) }
            // The run starting in front of text puts a space behind the user's caret (which stays before it).
            let keep = field.userCaret
            if trace, lastLane == .live, case .deleteBackward = op, field.caret > 0, field.origin[field.caret - 1] != .live {
                print("        BAD DELETE of", String(field.text[field.caret - 1]).debugDescription, "by live")
            }
            let before = field.caret
            field.racing = outsidePending
            field.apply(op)
            // A key that finished a dictated word carries the word's rest: that part is the run's (keys are one character).
            if lastLane == .user, case .insert(let s) = op, s.count > 1 {
                for i in before..<(before + s.count - 1) where i < field.origin.count { field.origin[i] = .live }
            }
            if behind { field.userCaret = keep }
            if syncUserCaret { field.userCaret = field.caret + queue.userCursor - queue.cursor }
            if field.lagTicks > 0 { break }
        }
    }

    mutating func run(ms: Double) { let end = clockMs + ms; while clockMs < end { tick() } }

    /// Ticks until the queue is idle (bounded); returns whether it got there.
    @discardableResult
    mutating func drain(limitMs: Double = 20_000) -> Bool {
        let end = clockMs + limitMs
        while clockMs < end {
            tick()
            if queue.isIdle, !queue.hasOpInFlight { tick(); if queue.isIdle { return true } }
        }
        return false
    }

    var drops: [FieldQueue.Drop] { events.compactMap { if case .dropped(let d) = $0.event { d } else { nil } } }
    var applied: [String] { events.compactMap { if case .applied(let id, _) = $0.event { id } else { nil } } }
}

func snap(_ version: Int, _ text: String, run: String = "r", complete: Bool = false) -> LiveDictationSnapshot {
    .init(runID: run, version: version, segments: [.init(id: 0, text: text, final: complete)], complete: complete)
}
