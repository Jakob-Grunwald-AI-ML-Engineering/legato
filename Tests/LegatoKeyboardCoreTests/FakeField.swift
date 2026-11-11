import Foundation
@testable import LegatoKeyboardCore

/// A text field that misbehaves like real hosts: late reports, a short window around the cursor, Safari's block echo
/// (`"\n "` where a window starts at a block), and emoji that move as one unit. With `hostDelays` it also behaves like
/// Safari as measured (2026-11 caret spike):
/// - the proxy reports a move at once (optimistically), while the host applies it 25–50 ms later;
/// - the host applies an edit 5–110 ms after it was sent, so ops sent close together can land out of order;
/// - an edit sent right after a move leaves the proxy on its post-move report until the next move.
/// `reorders` and `staleTriggers` count when the keyboard set off the last two: the queue must never.
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
    /// Safari's timing (see above); without it every op applies at once.
    var hostDelays = false
    /// After a tap, this many reports show the field's text as it was a few host turns ago (before the edits the keyboard
    /// confirmed last) with the caret where the user tapped: a stale report that reverts confirmed edits (UAT, Safari).
    var staleReportsAfterTap = 0
    private var truthLog: [[Character]] = []
    private var staleShow: (text: [Character], caret: Int, left: Int)?
    var nowMs = 0.0
    private(set) var reorders = 0
    private(set) var staleTriggers = 0
    private var history: [FieldQueue.Report] = []
    private var stuck: FieldQueue.Report?
    private var lastMoveSentMs = -1_000.0
    private var seq = 0
    private var rng = SeededGenerator(seed: 7)

    /// Who wrote each character, and who deleted what: the stress test's provenance checks.
    enum Origin: String { case initial, outside, user, live, edit }
    var origin: [Origin]
    var deletions: [(char: Character, origin: Origin, by: Origin, racing: Bool)] = []
    /// Where the user's caret is: taps and the user's moves put it there; edits before it shift it.
    var userCaret: Int
    /// For every user insert as it lands: the field's caret and the user's caret.
    var userInserts: [(caret: Int, userCaret: Int, racing: Bool)] = []

    /// How one op is to be carried out and accounted for.
    struct Send {
        var op: ShadowOp
        var writer = Origin.outside
        /// The op races with an outside action the queue has not seen yet.
        var racing = false
        /// The insert lands behind the user's caret (which stays in front of it).
        var behind = false
        /// The first characters of a user insert are the run's (a key that finished a dictated word).
        var runPrefix = 0
        /// After it lands, the user's caret is this far from the caret (the queue resynced after an outside action).
        var userOffset: Int?
    }
    private var pending: [(seq: Int, at: Double, send: Send)] = []

    init(_ text: String = "", caret: Int? = nil) {
        self.text = Array(text)
        self.caret = caret ?? self.text.count
        origin = Array(repeating: .initial, count: self.text.count)
        userCaret = self.caret
    }

    var string: String { String(text) }
    var settled: Bool { pending.isEmpty }

    private static func report(text: [Character], caret: Int, selection: Int, window: Int, blockEcho: Bool) -> FieldQueue.Report {
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

    /// The report as the proxy shows it now: the field, with moves not applied yet already in it.
    var current: FieldQueue.Report {
        let shown = proxy ?? (text, caret, selection)
        return Self.report(text: shown.text, caret: shown.caret, selection: shown.selection, window: window, blockEcho: blockEcho)
    }

    /// The proxy's own view: every op the keyboard sends shows in it at once (optimistically, measured in UAT for edits
    /// too); each time the host applies an op or the user acts, the host's truth replaces it, without the ops still on
    /// their way (a report that goes back to an older state).
    private var proxy: (text: [Character], caret: Int, selection: Int)?

    /// One host turn at `nowMs`: ops due land, and the (possibly late, possibly stale) report comes back.
    mutating func tick() -> FieldQueue.Report {
        let due = pending.filter { $0.at <= nowMs }.sorted { $0.at < $1.at }
        for item in due {
            pending.removeAll { $0.seq == item.seq }
            // An op sent earlier is still on its way: this one lands before it.
            if pending.contains(where: { $0.seq < item.seq }) {
                reorders += 1
                if ProcessInfo.processInfo.environment["LEGATO_STRESS_TRACE"] == "1" { print("        REORDER", item.send.op, "before", pending.filter { $0.seq < item.seq }.map { ($0.send.op, $0.at) }, "now", nowMs) }
            }
            carryOut(item.send)
            proxy = nil
        }
        truthLog.append(text)
        if truthLog.count > 12 { truthLog.removeFirst() }
        if var stale = staleShow, stale.left > 0 {
            stale.left -= 1; staleShow = stale.left > 0 ? stale : nil
            return Self.report(text: stale.text, caret: min(stale.caret, stale.text.count), selection: 0, window: window, blockEcho: blockEcho)
        }
        history.append(current)
        if history.count > lagTicks + 1 { history.removeFirst(history.count - lagTicks - 1) }
        return stuck ?? history.first!
    }

    /// The keyboard sends an op.
    mutating func send(_ send: Send) {
        guard hostDelays else { carryOut(send); return }
        defer {
            var view = self
            view.hostDelays = false
            if let proxy { view.text = proxy.text; view.caret = proxy.caret; view.selection = proxy.selection; view.origin = Array(repeating: .initial, count: proxy.text.count) }
            view.carryOut(Send(op: send.op))
            proxy = (view.text, view.caret, view.selection)
        }
        seq += 1
        var delay: Double
        if case .move = send.op {
            stuck = nil
            lastMoveSentMs = nowMs
            delay = Double.random(in: 25...50, using: &rng)
        } else {
            if nowMs - lastMoveSentMs < 30 { stuck = current; staleTriggers += 1 }
            delay = Double.random(in: 5...110, using: &rng)
        }
        pending.append((seq, nowMs + delay, send))
    }

    /// Applies an op right away (the in-process harness, or tests that drive the field by hand).
    mutating func apply(_ op: ShadowOp) { carryOut(Send(op: op)) }

    private mutating func carryOut(_ send: Send) {
        switch send.op {
        case .move(let units):
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
            if send.writer == .user { userCaret = caret }
        case .deleteBackward(let count):
            for _ in 0..<count {
                if selection > 0 { remove(caret..<(caret + selection), send); selection = 0; continue }
                guard caret > 0 else { break }
                remove((caret - 1)..<caret, send); caret -= 1
            }
        case .insert(let string):
            if send.writer == .user { userInserts.append((caret, userCaret, send.racing)) }
            if selection > 0 { remove(caret..<(caret + selection), send); selection = 0 }
            let chars = Array(string)
            text.insert(contentsOf: chars, at: caret)
            var origins = Array(repeating: send.writer, count: chars.count)
            for i in 0..<min(send.runPrefix, origins.count) { origins[i] = .live }
            origin.insert(contentsOf: origins, at: caret)
            if userCaret > caret || (userCaret == caret && !send.behind) { userCaret += chars.count }
            caret += chars.count
        }
        if let offset = send.userOffset { userCaret = caret + offset }
    }

    private mutating func remove(_ range: Range<Int>, _ send: Send) {
        for i in range { deletions.append((text[i], origin[i], send.writer, send.racing)) }
        text.removeSubrange(range); origin.removeSubrange(range)
        if userCaret >= range.upperBound { userCaret -= range.count } else if userCaret > range.lowerBound { userCaret = range.lowerBound }
    }

    /// The user's caret is this far from the caret once what is on its way has landed.
    mutating func setUserOffset(_ offset: Int) {
        if let last = pending.indices.max(by: { pending[$0].at < pending[$1].at }) { pending[last].send.userOffset = offset }
        else { userCaret = caret + offset }
    }

    /// The user taps somewhere (outside the keyboard).
    mutating func tap(at index: Int) {
        outsideNow(); caret = max(0, min(text.count, index)); selection = 0; userCaret = caret
        if staleReportsAfterTap > 0, let old = truthLog.first {
            // The tap at the same place in the older text (counted from the start: the user tapped there).
            staleShow = (old, caret, staleReportsAfterTap)
        }
    }
    mutating func select(_ range: Range<Int>) { outsideNow(); caret = range.lowerBound; selection = range.count; userCaret = caret }
    /// Another keyboard (a hardware keyboard) types: invisible to the queue except through reports.
    mutating func typeOutside(_ string: String) { outsideNow(); carryOut(Send(op: .insert(string), writer: .outside)) }
    /// Ops already on their way when the user acts outside the keyboard race with it (as on a real host).
    private mutating func outsideNow() { for i in pending.indices { pending[i].send.racing = true }; proxy = nil }
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
    /// The user acted outside the keyboard (tap, selection, another keyboard) and the queue has not resynced since.
    var outsidePending = false { didSet { if outsidePending { outsideAtMs = clockMs } } }
    private var outsideAtMs = -1_000_000.0
    /// An op sent now races with an outside action: the queue has not resynced since, or it was a moment ago (an
    /// op already on its way, a report still late).
    private var racing: Bool { outsidePending || clockMs - outsideAtMs < FieldQueue.confirmLimitMs + 200 }

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
        field.nowMs = clockMs
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
                // An outside action (a tap, a selection, another keyboard typing) races with the queue's own moves and is
                // revealed by late reports, sometimes in several steps. Where the user meant their caret then cannot be
                // known by any keyboard (another keyboard typed at a caret a unit had moved): at each resync within the
                // race window the queue's choice becomes the expectation. Outside that window nothing is excused.
                if racing, case .resync(let kind) = event, kind == .cursorMoved || kind == .reseeded || kind == .outsideInsert {
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
                if syncUserCaret { field.setUserOffset(queue.userCursor - queue.cursor) }
                break
            }
            sent.append((clockMs, op))
            let writer: FakeField.Origin = lastLane.map { lane in lane == .user ? .user : lane == .live ? .live : .edit } ?? .edit
            var send = FakeField.Send(op: op, writer: writer, racing: racing, behind: behind)
            // A key that finished a dictated word carries the word's rest: that part is the run's (keys are one character).
            if writer == .user, case .insert(let s) = op, s.count > 1 { send.runPrefix = s.count - 1 }
            if syncUserCaret { send.userOffset = queue.userCursor - queue.cursor }
            field.send(send)
            if field.lagTicks > 0 || field.hostDelays { break }
        }
    }

    mutating func run(ms: Double) { let end = clockMs + ms; while clockMs < end { tick() } }

    /// Ticks until the queue is idle (bounded); returns whether it got there.
    @discardableResult
    mutating func drain(limitMs: Double = 20_000) -> Bool {
        let end = clockMs + limitMs
        while clockMs < end {
            tick()
            if queue.isIdle, !queue.hasOpInFlight, field.settled { tick(); if queue.isIdle { return true } }
        }
        return false
    }

    var drops: [FieldQueue.Drop] { events.compactMap { if case .dropped(let d) = $0.event { d } else { nil } } }
    var applied: [String] { events.compactMap { if case .applied(let id, _) = $0.event { id } else { nil } } }
}

func snap(_ version: Int, _ text: String, run: String = "r", complete: Bool = false) -> LiveDictationSnapshot {
    .init(runID: run, version: version, segments: [.init(id: 0, text: text, final: complete)], complete: complete)
}
