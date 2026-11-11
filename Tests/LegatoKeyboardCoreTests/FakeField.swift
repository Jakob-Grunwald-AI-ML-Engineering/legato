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

    init(_ text: String = "", caret: Int? = nil) {
        self.text = Array(text)
        self.caret = caret ?? self.text.count
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
        case .deleteBackward(let count):
            for _ in 0..<count {
                if selection > 0 { text.removeSubrange(caret..<(caret + selection)); selection = 0; continue }
                guard caret > 0 else { break }
                text.remove(at: caret - 1); caret -= 1
            }
        case .insert(let string):
            if selection > 0 { text.removeSubrange(caret..<(caret + selection)); selection = 0 }
            text.insert(contentsOf: Array(string), at: caret)
            caret += string.count
        }
    }

    /// The user taps somewhere (outside the keyboard).
    mutating func tap(at index: Int) { caret = max(0, min(text.count, index)); selection = 0 }
    mutating func select(_ range: Range<Int>) { caret = range.lowerBound; selection = range.count }
    /// Another keyboard (a hardware keyboard) types: invisible to the queue except through reports.
    mutating func typeOutside(_ string: String) { apply(.insert(string)) }
}

/// The keyboard's loop in miniature: steps the queue against a `FakeField` every `tickMs`.
struct QueueRig {
    var queue: FieldQueue
    var field: FakeField
    var tickMs = 33.0
    var clockMs = 0.0
    var sent: [(ms: Double, op: ShadowOp)] = []
    var events: [(ms: Double, event: FieldQueue.Event)] = []
    var maxInFlight = 0

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
            for event in queue.drainEvents() { events.append((clockMs, event)) }
            guard case .send(let op) = action else { break }
            sent.append((clockMs, op))
            field.apply(op)
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
