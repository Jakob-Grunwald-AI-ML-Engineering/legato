import Foundation
@testable import LegatoKeyboardCore

/// A text field that misbehaves like real hosts: late reports, a short window around the cursor, Safari's block echo
/// (`"\n "` where a window starts at a block), and emoji that move as one unit. With `hostDelays` it also behaves like
/// Safari as measured (2026-11 caret spike, and the burst probe of 2026-11-16):
/// - the proxy reports every op at once (optimistically), while the host applies a move 25–50 ms later and an edit
///   5–110 ms later; ops land in the order sent (a burst of hop, delete run, insert and hop back landed 15/15);
/// - an edit sent right after a move leaves the proxy on its post-move report until the next move.
/// `reorders` counts ops that landed out of order (never, by the measured model); `staleTriggers` counts edits sent right
/// after a move (a chunk does that by design: its return hop refreshes the proxy). `Host` presets add the rest of the
/// measured behaviour (windows, units, dropped overshoot, Safari's stale first callback, identity on empty).
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
    /// Reports never show a selection (Safari's opaque Select All): the caret shows at its end, nothing selected.
    var hidesSelection = false

    // Measured on the iPhone (2026-11-16, `docs/field-editing.md`, "Measured host behaviour").
    /// Windows stop at a line break on either side (WhatsApp, Notes), without Safari's "\n " echo.
    var cutsAtLineBreaks = false
    /// A move past the end of the text is dropped entirely: the caret stays (WhatsApp).
    var dropsOvershoot = false
    /// The first report of a new host turn after a move still shows the caret where it was (Safari's first callback).
    var staleFirstMoveReport = false
    /// The field gets a new document identity when its text becomes empty (Notes, Safari).
    var newIdentityWhenEmpty = false
    /// The field's document identity (changes with `newIdentityWhenEmpty`).
    private(set) var identity = 0
    /// Host callbacks (`textDidChange`) so far: one per move as it lands (two in Safari, the first stale); the keyboard's
    /// own inserts and deletes make none. `unheard` are those no fresh report has carried yet (`takeCallback`).
    private(set) var callbacks = 0
    private var unheard = 0
    /// Whether the next fresh report comes with a host callback.
    mutating func takeCallback() -> Bool {
        guard unheard > 0 else { return false }
        unheard -= 1
        return true
    }
    private var staleMove: (caret: Int, armed: Bool)?

    enum Host { case whatsApp, notes, safari }
    /// A field that behaves like `host` as measured.
    static func host(_ host: Host, _ text: String = "", caret: Int? = nil) -> FakeField {
        var field = FakeField(text, caret: caret)
        switch host {
        case .whatsApp: field.window = 300; field.cutsAtLineBreaks = true; field.dropsOvershoot = true
        case .notes: field.window = 300; field.cutsAtLineBreaks = true; field.newIdentityWhenEmpty = true
        case .safari:
            field.window = 100; field.movesByCharacters = true; field.hostDelays = true
            field.staleFirstMoveReport = true; field.newIdentityWhenEmpty = true
        }
        return field
    }
    private var truthLog: [[Character]] = []
    private var staleShow: (text: [Character], caret: Int, left: Int)?
    var nowMs = 0.0
    private(set) var reorders = 0
    private(set) var staleTriggers = 0
    private var history: [FieldQueue.Report] = []
    private var stuck: FieldQueue.Report?
    private var lastMoveSentMs = -1_000.0
    private var seq = 0
    /// The host's delays (settable: a timing report averages over several).
    var rng = SeededGenerator(seed: 7)

    /// Who wrote each character, and who deleted what: the stress test's provenance checks.
    enum Origin: String { case initial, outside, user, live, edit }
    var origin: [Origin]
    var deletions: [(char: Character, origin: Origin, by: Origin, racing: Bool)] = []
    /// Where the user's caret is: taps and the user's moves put it there; edits before it shift it.
    var userCaret: Int
    /// For every user insert as it lands: the field's caret and the user's caret.
    var userInserts: [(caret: Int, userCaret: Int, racing: Bool)] = []
    /// For every insert of the live run as it lands: whether it went at the user's caret, or near the run's own text in
    /// this field (within four characters), or where the run just deleted its own.
    var liveInserts: [(atUserCaret: Bool, touchesOwn: Bool, racing: Bool, at: String)] = []
    private var liveDeletedAt: Int?
    /// A keyboard op on its way replaced a selection the user made meanwhile: the field now holds text no report showed
    /// the keyboard before (what was selected is gone), so where the user's caret is cannot be known from then on.
    var clobberedSelection = false
    /// The user's actions so far (keys, deletes, moves, taps, selections, another keyboard), and for each character the
    /// count when it was written: dictation may delete or move over only its own characters written since the last.
    private(set) var userActions = 0
    private(set) var epochs: [Int] = []
    /// Characters an op racing with an outside action wrote (it may land where the user tapped: no keyboard can tell).
    private(set) var raced: [Bool] = []
    /// Dictation deleted or moved over text from before the user's last action (not racing with it).
    private(set) var frozenEdits: [String] = []
    /// The keyboard's own deletes and moves (dictation's, or another lane's) after the user's first action since
    /// dictation began typing here (not racing with it): a session's single take may make none (once the user acted
    /// during or after the take, it is only appended to). Edits (Magic) make their own.
    private(set) var ownEditsAfterUser: [(writer: Origin, what: String)] = []
    var liveEditsAfterUser: [String] { ownEditsAfterUser.filter { $0.writer == .live }.map(\.what) }
    private var actionsAtFirstLive: Int?
    /// Reports cut the text before the caret short this often (a truncated, lagging proxy window).
    var truncation = 0.0
    var truncationRng = SeededGenerator(seed: 11)

    /// How one op is to be carried out and accounted for.
    struct Send {
        var op: ShadowOp
        var writer = Origin.outside
        /// The op races with an outside action the queue has not seen yet.
        var racing = false
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
        epochs = Array(repeating: 0, count: self.text.count)
        raced = Array(repeating: false, count: self.text.count)
        userCaret = self.caret
    }

    var string: String { String(text) }
    var settled: Bool { pending.isEmpty }

    private static func report(text: [Character], caret: Int, selection: Int, window: Int, blockEcho: Bool,
                               cutsAtLineBreaks: Bool = false) -> FieldQueue.Report {
        var start = max(0, caret - window)
        var prefix = ""
        if blockEcho, let breakIndex = text[start..<caret].lastIndex(where: \.isNewline) {
            start = breakIndex + 1
            prefix = "\n "
        } else if cutsAtLineBreaks, let breakIndex = text[start..<caret].lastIndex(where: \.isNewline) {
            start = breakIndex + 1
        }
        let before = prefix + String(text[start..<caret])
        let selected = selection > 0 ? String(text[caret..<(caret + selection)]) : nil
        let afterStart = caret + selection
        var afterEnd = min(text.count, afterStart + window)
        if cutsAtLineBreaks, let breakIndex = text[afterStart..<afterEnd].firstIndex(where: \.isNewline) { afterEnd = breakIndex }
        let after = String(text[afterStart..<afterEnd])
        return .init(before: before, after: after, selected: selected)
    }

    /// The report as the proxy shows it now: the field, with moves not applied yet already in it.
    var current: FieldQueue.Report {
        let shown = proxy ?? (text, caret, selection)
        if hidesSelection {
            return Self.report(text: shown.text, caret: shown.caret + shown.selection, selection: 0, window: window, blockEcho: blockEcho, cutsAtLineBreaks: cutsAtLineBreaks)
        }
        return Self.report(text: shown.text, caret: shown.caret, selection: shown.selection, window: window, blockEcho: blockEcho, cutsAtLineBreaks: cutsAtLineBreaks)
    }

    /// Now and then a report shows less before the caret than the window (never more, never other text).
    private mutating func truncated(_ report: FieldQueue.Report) -> FieldQueue.Report {
        guard truncation > 0, !report.before.isEmpty, Double.random(in: 0..<1, using: &truncationRng) < truncation else { return report }
        var cut = report
        // Never below a few characters: an empty window is the field's start, which no truncation shows (UAT: 288 → 47).
        let keep = min(report.before.count, 8)
        guard keep < report.before.count else { return report }
        cut.before = String(report.before.suffix(Int.random(in: keep..<report.before.count, using: &truncationRng)))
        return cut
    }

    /// The proxy's own view: every op the keyboard sends shows in it at once (optimistically, measured in UAT for edits
    /// too); each time the host applies an op or the user acts, the host's truth replaces it, without the ops still on
    /// their way (a report that goes back to an older state).
    private var proxy: (text: [Character], caret: Int, selection: Int)?

    /// One host turn at `nowMs`: ops due land, and the (possibly late, possibly stale) report comes back. `fresh`: a new
    /// turn (a callback), not the keyboard reading the proxy again right after its own op.
    /// `callback`: the read comes with a host callback, which carries the host's state at that moment (no lag).
    mutating func tick(fresh: Bool = true, callback: Bool = false) -> FieldQueue.Report {
        if fresh, let stale = staleMove, stale.armed {
            // Safari's first callback after a move: the old caret, once.
            staleMove = nil
            return Self.report(text: text, caret: min(stale.caret, text.count), selection: 0, window: window, blockEcho: blockEcho, cutsAtLineBreaks: cutsAtLineBreaks)
        }
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
            return Self.report(text: stale.text, caret: min(stale.caret, stale.text.count), selection: 0, window: window, blockEcho: blockEcho, cutsAtLineBreaks: cutsAtLineBreaks)
        }
        history.append(current)
        if history.count > lagTicks + 1 { history.removeFirst(history.count - lagTicks - 1) }
        if callback { return truncated(stuck ?? current) }
        return truncated(stuck ?? history.first!)
    }

    /// The keyboard sends an op.
    mutating func send(_ send: Send) {
        guard hostDelays else { carryOut(send); return }
        defer {
            var view = self
            view.hostDelays = false
            if let proxy { view.text = proxy.text; view.caret = proxy.caret; view.selection = proxy.selection; view.origin = Array(repeating: .initial, count: proxy.text.count); view.epochs = Array(repeating: 0, count: proxy.text.count); view.raced = Array(repeating: false, count: proxy.text.count) }
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
        // Ops land in the order sent (burst probe, 2026-11-16: every stage in order, in every host).
        var at = nowMs + delay
        if let last = pending.max(by: { $0.seq < $1.seq }) { at = max(at, last.at + 1) }
        pending.append((seq, at, send))
    }

    static func sameKind(_ a: ShadowOp, _ b: ShadowOp) -> Bool {
        switch (a, b) {
        case (.move, .move), (.insert, .insert), (.deleteBackward, .deleteBackward): true
        default: false
        }
    }

    /// Applies an op right away (the in-process harness, or tests that drive the field by hand).
    mutating func apply(_ op: ShadowOp) { carryOut(Send(op: op)) }

    private mutating func carryOut(_ send: Send) {
        if send.writer == .user { userActions += 1 }
        let checks = send.writer == .live && !send.racing
        if send.writer == .live, actionsAtFirstLive == nil { actionsAtFirstLive = userActions }
        if send.writer == .live || send.writer == .edit, !send.racing, let first = actionsAtFirstLive, userActions > first {
            switch send.op {
            case .move(let n) where n != 0: ownEditsAfterUser.append((send.writer, "move \(n)"))
            case .deleteBackward(let n): ownEditsAfterUser.append((send.writer, "delete \(n)"))
            default: break
            }
        }
        let from = caret
        let wasEmpty = text.isEmpty
        defer {
            if newIdentityWhenEmpty, text.isEmpty, !wasEmpty { identity += 1 }
            if case .move = send.op {
                let calls = staleFirstMoveReport ? 2 : 1
                callbacks += calls; unheard += calls
                if staleFirstMoveReport, send.writer != .outside { staleMove = (from, true) }
            }
            if checks, case .move = send.op {
                let crossed = min(from, caret)..<max(from, caret)
                if crossed.contains(where: { epochs[$0] != userActions }) {
                    frozenEdits.append("move over \(String(text[crossed]).debugDescription) after the user acted")
                }
            }
        }
        switch send.op {
        case .move(let units):
            if selection > 0 { if units >= 0 { caret += selection }; selection = 0 }
            if dropsOvershoot, units > 0, String(text[caret...]).utf16.count < units { break }
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
            // The user's own move; or dictation's from the user's caret (a take that starts inside a word goes to its end
            // first: the user's caret goes with it, the keys follow the take).
            if send.writer == .user || (send.writer == .live && from == userCaret) { userCaret = caret }
        case .deleteBackward(let count):
            for _ in 0..<count {
                if selection > 0 {
                    if send.racing, send.writer != .outside { clobberedSelection = true }
                    remove(caret..<(caret + selection), send); selection = 0; continue
                }
                guard caret > 0 else { break }
                remove((caret - 1)..<caret, send); caret -= 1
            }
        case .insert(let string):
            if send.writer == .user { userInserts.append((caret, userCaret, send.racing)) }
            if send.writer == .live, selection == 0 {
                // Near the run's own text (a user's letter glued onto its word stays inside the region it edited).
                let near = origin[max(0, caret - 4)..<min(text.count, caret + 4)]
                let own = near.contains(.live) || liveDeletedAt == caret
                liveInserts.append((caret == userCaret, own, send.racing, "\(string.debugDescription) caret \(caret) user \(userCaret) insert \(send.op)"))
            }
            if selection > 0 {
                if send.racing, send.writer != .outside { clobberedSelection = true }
                remove(caret..<(caret + selection), send); selection = 0
            }
            let chars = Array(string)
            text.insert(contentsOf: chars, at: caret)
            var origins = Array(repeating: send.writer, count: chars.count)
            for i in 0..<min(send.runPrefix, origins.count) { origins[i] = .live }
            origin.insert(contentsOf: origins, at: caret)
            epochs.insert(contentsOf: Array(repeating: userActions, count: chars.count), at: caret)
            raced.insert(contentsOf: Array(repeating: send.racing, count: chars.count), at: caret)
            if userCaret >= caret { userCaret += chars.count }
            caret += chars.count
        }
        if let offset = send.userOffset { userCaret = caret + offset }
    }

    private mutating func remove(_ range: Range<Int>, _ send: Send) {
        for i in range { deletions.append((text[i], origin[i], send.writer, send.racing)) }
        if send.writer == .live { liveDeletedAt = range.lowerBound }
        if send.writer == .live, !send.racing, range.contains(where: { epochs[$0] != userActions }) {
            frozenEdits.append("delete of \(String(text[range]).debugDescription) after the user acted")
        }
        text.removeSubrange(range); origin.removeSubrange(range); epochs.removeSubrange(range); raced.removeSubrange(range)
        if userCaret >= range.upperBound { userCaret -= range.count } else if userCaret > range.lowerBound { userCaret = range.lowerBound }
    }

    /// The user's caret is this far from the caret once what is on its way has landed.
    mutating func setUserOffset(_ offset: Int) {
        if let last = pending.indices.max(by: { pending[$0].at < pending[$1].at }) { pending[last].send.userOffset = offset }
        else { userCaret = caret + offset }
    }

    /// The user taps somewhere (outside the keyboard).
    mutating func tap(at index: Int) {
        // A tap where the caret already is moves nothing (no keyboard can see it).
        let to = max(0, min(text.count, index))
        outsideNow(counts: to != caret || selection > 0); caret = to; selection = 0; userCaret = caret
        if staleReportsAfterTap > 0, let old = truthLog.first {
            // The tap at the same place in the older text (counted from the start: the user tapped there).
            staleShow = (old, caret, staleReportsAfterTap)
        }
    }
    mutating func select(_ range: Range<Int>) { outsideNow(); caret = range.lowerBound; selection = range.count; userCaret = caret }
    /// Another keyboard (a hardware keyboard) types: invisible to the queue except through reports.
    mutating func typeOutside(_ string: String) { outsideNow(); carryOut(Send(op: .insert(string), writer: .outside)) }
    /// Ops already on their way when the user acts outside the keyboard race with it (as on a real host).
    private mutating func outsideNow(counts: Bool = true) {
        if counts { userActions += 1 }
        for i in pending.indices { pending[i].send.racing = true }
        proxy = nil
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
    /// The user acted outside the keyboard (tap, selection, another keyboard) and the queue has not resynced since.
    var outsidePending = false { didSet { if outsidePending { outsideAtMs = clockMs } } }
    private var outsideAtMs = -1_000_000.0

    /// The user moved to another field (the queue is not told): ops on their way race with it, but the user's caret is
    /// known, where they tapped, so the queue's choice does not become the expectation.
    mutating func fieldSwitched() { outsideAtMs = clockMs; switchedAtMs = clockMs }
    private var switchedAtMs = -1_000_000.0
    private var switching: Bool { clockMs - switchedAtMs < FieldQueue.checkDeadlineMs + 400 }
    /// An op sent now races with an outside action: the queue has not resynced since, or it was a moment ago (an
    /// op already on its way, a report still late).
    private var racing: Bool { outsidePending || clockMs - outsideAtMs < FieldQueue.checkDeadlineMs + 400 }

    /// Prints every step (`LEGATO_STRESS_TRACE=1`).
    var trace = ProcessInfo.processInfo.environment["LEGATO_STRESS_TRACE"] == "1"

    init(_ field: FakeField, config: FieldQueue.Config = .init()) {
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
        for iteration in 0..<64 {
            // The first read of a tick is a host callback; the reads that follow the keyboard's own ops are the proxy's
            // immediate view.
            let callback = iteration == 0 && field.takeCallback()
            let report = field.tick(fresh: iteration == 0, callback: callback)
            let action = queue.step(report: report, elapsedMs: elapsed, callback: callback)
            elapsed = 0
            var syncUserCaret = false
            for event in queue.drainEvents() {
                events.append((clockMs, event))
                if case .sent(_, let lane) = event { lastLane = lane }
                // An outside action (a tap, a selection, another keyboard typing) races with the queue's own moves and is
                // revealed by late reports, sometimes in several steps. Where the user meant their caret then cannot be
                // known by any keyboard (another keyboard typed at a caret a unit had moved): at each resync within the
                // race window the queue's choice becomes the expectation. Outside that window nothing is excused.
                if racing, !switching, case .resync(let kind) = event, kind == .cursorMoved || kind == .reseeded || kind == .outsideInsert {
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
            var send = FakeField.Send(op: op, writer: writer, racing: racing)
            // A key that finished a dictated word carries the word's rest: that part is the run's (keys are one character).
            if writer == .user, case .insert(let s) = op, s.count > 1 { send.runPrefix = s.count - 1 }
            if syncUserCaret { send.userOffset = queue.userCursor - queue.cursor }
            field.send(send)
            if field.lagTicks > 0 || field.hostDelays, !queue.isInChunk { break }
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
