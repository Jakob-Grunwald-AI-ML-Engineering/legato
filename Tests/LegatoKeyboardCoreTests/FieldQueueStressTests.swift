import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Seeded random sessions against a misbehaving field: late reports, short windows, Safari's block echo, emoji that
/// move as one unit; dictation that grows, flips and gets cleaned up (in some sessions late, after the user deleted,
/// moved and tapped: the cleanup must start no region at the user's cursor); the user's keys, deletes, cursor moves, taps,
/// selections and outside typing; Magic edits; a switch to another field of the page with work for the old one pending
/// (the queue is not told). Each seed also runs a `ListSession`. CI runs a few dozen seeds; `LEGATO_STRESS_RUNS=5000`
/// runs a long local pass, and `LEGATO_STRESS_SEED=<n>` replays one seed (`LEGATO_STRESS_NO_SWITCH=1`,
/// `LEGATO_STRESS_NO_LIST=1` leave those parts out).
@Suite struct FieldQueueStressTests {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Seeds that once failed, kept as regressions (each named fix is in `FieldQueue`):
    /// - 230: a late report of the state before the op fit there among other places; the resync then "found" the cursor
    ///   at the model's end, where any text after it fits. Wrong final text.
    /// - 265, 398, 615, 2251, 2989: a resync while a unit had the caret away, with text between caret and user cursor
    ///   changed unseen: the jumped caret was taken for the user's cursor (keys and dictation landed mid-text). The
    ///   queue now finds the user's cursor again by the text around it, or moves the caret back the distance it came.
    /// - 856, 1138: text another keyboard typed right at the caret: now taken into the model as the user's typing, and
    ///   only with as much agreeing text as any other relocation (a looser match deleted the user's text).
    /// - 1035: a lagging field and a long flip: deletes of one change now go in one op.
    /// - 2729: an op whose report fit the states before and after it was taken as landed without saying so.
    /// - 4568: a space typed at a block's start hid behind Safari's "\n " echo; the key was judged lost and sent twice.
    /// UAT round (Safari echoes edits at once; reports after a tap show older text):
    /// - 69, 190: a tap while an op was in flight; nothing may follow an unconfirmed op before the host's transit.
    /// - 241, 3569: repetitive text and an empty side of the window looked like a tap or an older state.
    /// - 548, 1392: the user's key landed where they tapped and must not be sent again.
    /// - 1376: the keyboard's own insert landed at the tap and was taken out again.
    /// - 1121: an edit's scope grew the model at the field's start with no agreeing text (duplicated text).
    /// - 1615: a lost delete that counted as landed later looked like another keyboard's typing.
    /// Spans and pace round:
    /// - 1555: an emptied block ("\n " then a space) fit only past the model's end; the echo reading counts too.
    /// - 1886 (exempt, unknowable): the user selected text while the keyboard's insert was on its way; the insert
    ///   replaced the selection, so the field holds text no report showed. Key placement is not asserted after that.
    @Test(arguments: [UInt64(69), 190, 230, 241, 265, 398, 548, 615, 856, 1035, 1121, 1138, 1376, 1392, 1555, 1615, 1886, 2251, 2729, 2989, 3569, 4568])
    func pinnedSeedsKeepTheInvariants(seed: UInt64) {
        var session = StressSession(seed: seed, lateCleanups: false, fieldSwitches: false)
        if let failure = session.run() { Issue.record("seed \(seed): \(failure)") }
    }

    /// Late cleanups and regions the user edited:
    /// - 944: raw words out of sight after a resync still start at the cursor (not the cleanup's doing).
    /// - 165, 1571: a merge into a region the user edited deleted and retyped the user's letter (a whole-word span; a
    ///   diff that took the user's "a" for the keyboard's). The queue now knows who wrote each character.
    /// Faster settles (iOS parity with the Mac):
    /// - 2930, 4414: a tap seen only through a short window while the live insert was on its way; the insert landed at
    ///   the tap and was taken for another keyboard's typing, so the model kept it twice (a stall). A resync that finds
    ///   the user's caret elsewhere now expects the ops on their way to land there, as after a tap.
    /// - 4167: a tap at the field's end with the live insert landing there read as another keyboard's typing at the
    ///   caret (the report's empty window after the caret fit anything); the model kept the text after it twice.
    @Test(arguments: [UInt64(165), 944, 1571, 2930, 4167, 4414])
    func pinnedLateCleanupSeedsKeepTheInvariants(seed: UInt64) {
        var session = StressSession(seed: seed, fieldSwitches: false)
        if let failure = session.run() { Issue.record("seed \(seed): \(failure)") }
    }

    /// Field switches and list sessions (UAT F1–F3), seeds that once failed:
    /// - 206, 444: a switch while a jump unit had the caret away; the reseed's way back (the old field's distance) moved
    ///   the user's caret in the new field. It now goes back only when the report shares text with the old model there,
    ///   and a way back cut short by the field's edge leaves the user where the caret was.
    /// - 3794: a tiny report of the new field fit the old model elsewhere; a jump went out on it. Nothing of the
    ///   keyboard's own starts while the report does not show the model at the caret.
    /// - 4687: the user's key waited while a jump into the old field was in flight; the jump was assumed landed and the way
    ///   back threw the caret to the new field's start. A jump still shown at its start then fails.
    /// - 1638: a unit's way back to the user went out on an unshown model (the new field's report fit it elsewhere).
    /// - 3227: the new field held the old text's end; four agreeing characters sent the caret back the old distance.
    /// - 3066, 1250: a list line repeated further down, under Safari's block echo, pinned the first line.
    @Test(arguments: [UInt64(206), 444, 1250, 1638, 3066, 3227, 3794, 4687])
    func pinnedFieldSwitchAndListSeedsKeepTheInvariants(seed: UInt64) {
        var session = StressSession(seed: seed)
        var list = ListSession(seed: seed)
        if let failure = session.run() ?? list.run().map({ "list session: \($0)" }) { Issue.record("seed \(seed): \(failure)") }
    }

    @Test func seededSessionsKeepTheInvariants() {
        let runs = Self.environment["LEGATO_STRESS_RUNS"].flatMap(Int.init) ?? 48
        // `LEGATO_STRESS_FIRST` starts a long run elsewhere (parallel shards).
        let first = (Self.environment["LEGATO_STRESS_SEED"] ?? Self.environment["LEGATO_STRESS_FIRST"]).flatMap(UInt64.init) ?? 1
        var failures = 0
        for i in 0..<(Self.environment["LEGATO_STRESS_SEED"] == nil ? runs : 1) {
            let seed = first &+ UInt64(i)
            // Names each seed before it runs, so a crash says which one to replay.
            if Self.environment["LEGATO_STRESS_PROGRESS"] == "1" { print("stress seed \(seed)") }
            var session = StressSession(seed: seed, fieldSwitches: Self.environment["LEGATO_STRESS_NO_SWITCH"] == nil)
            var list = ListSession(seed: seed)
            let lists = Self.environment["LEGATO_STRESS_NO_LIST"] == nil
            if let failure = session.run() ?? (lists ? list.run().map({ "list session: \($0)" }) : nil) {
                Issue.record("seed \(seed) (replay: LEGATO_STRESS_SEED=\(seed)): \(failure)")
                failures += 1
                if failures >= 5 { break }
            }
        }
    }
}

/// A Markdown list dictated in one run (UAT F1, F3): the user types "- " and "\n- " between the items, the run's
/// segments go on after a stop (the run is complete, then new speech comes), and the cleanups join the items into one
/// sentence (", ", "; ", ". ", " and "), early, mid-list or at the end. Every item starts at the caret and keeps its own
/// words; no joiner lands at an item's start.
struct ListSession {
    private var rng: SeededGenerator
    init(seed: UInt64) { rng = SeededGenerator(seed: seed ^ 0x115715) }

    private mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    private mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &rng)] }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The run's snapshot with its first `count` items cleaned into one sentence (one unit over their segments), the
    /// later ones raw.
    private static func cleanup(_ items: [String], count: Int, joiner: String, run: String, version: Int) -> LiveDictationSnapshot {
        let text = pieces(Array(items[..<count]), joiner: joiner).joined(separator: joiner) + "."
        return LiveDictationSnapshot(runID: run, version: version, segments: items.enumerated().map { i, item in
            guard i < count else { return LiveSegment(id: i, text: item, final: true) }
            return LiveSegment(id: i, text: i == 0 ? text : "", cleaned: true, final: true, unit: count > 1 ? 0 : nil, raw: count > 1 ? item : nil)
        }, complete: true)
    }

    private static func pieces(_ items: [String], joiner: String) -> [String] {
        items.enumerated().map { i, item in i == 0 || joiner == ". " ? capitalized(item) : item }
    }

    mutating func run() -> String? {
        let words = ["alpha", "beta", "gamma", "delta", "river", "stone", "light", "table", "green", "quiet", "north", "maple"]
        let initial = pick(["", "Notes:\n", "Shopping\n"])
        var field = FakeField(initial)
        field.hostDelays = chance(0.7)
        field.lagTicks = chance(0.3) ? Int.random(in: 1...3, using: &rng) : 0
        field.window = Int.random(in: 20...80, using: &rng)
        field.blockEcho = chance(0.3)
        var rig = QueueRig(field, config: .init(animated: chance(0.6)))
        let items = (0..<Int.random(in: 2...4, using: &rng)).map { _ in
            (0..<Int.random(in: 1...4, using: &rng)).map { _ in pick(words) }.joined(separator: " ")
        }
        let joiner = pick([", ", "; ", ". ", " and "])
        // The take is stopped after each item and its run goes on (the bridge reuses it): F1.
        let stops = chance(0.5)
        let run = "list"
        var version = 0
        var finals: [LiveSegment] = []
        // How many items the last cleanup covered, and one still to come.
        var cleanedCount = 0
        var pendingCleanup = false

        // At a person's pace (the UAT typed a key about every 0.7 s); fast typing races are the main session's.
        func typeKeys(_ keys: String, _ rig: inout QueueRig, _ rng: inout SeededGenerator) {
            for key in keys { rig.queue.enqueue(.insert(String(key))); rig.run(ms: Double.random(in: 120...300, using: &rng)) }
        }
        func publishCleanup(_ rig: inout QueueRig) {
            version += 1; cleanedCount = finals.count; pendingCleanup = false
            rig.queue.enqueue(Self.cleanup(Array(items[..<finals.count]), count: finals.count, joiner: joiner, run: run, version: version))
        }

        for (i, item) in items.enumerated() {
            // The item before is typed whole (a key cut short would end its region mid-item), and its cleanup is maybe
            // still on its way while the user types the next line's start.
            rig.drain()
            let prefix = i == 0 ? "- " : "\n- "
            if pendingCleanup {
                let split = Int.random(in: 0...prefix.count, using: &rng)
                typeKeys(String(prefix.prefix(split)), &rig, &rng)
                publishCleanup(&rig)
                typeKeys(String(prefix.dropFirst(split)), &rig, &rng)
            } else {
                typeKeys(prefix, &rig, &rng)
            }
            if !stops || i == 0 {
                // Words arrive as the speaking head (a stopped take's later speech comes as finals only).
                var head = ""
                for word in item.split(separator: " ") {
                    head += (head.isEmpty ? "" : " ") + word
                    version += 1
                    let before = cleanedCount > 0 ? Self.cleanup(Array(items[..<finals.count]), count: cleanedCount, joiner: joiner, run: run, version: 0).segments : finals
                    rig.queue.enqueue(LiveDictationSnapshot(runID: run, version: version, segments: before + [.init(id: i, text: head, final: false)]))
                    rig.run(ms: Double.random(in: 60...400, using: &rng))
                }
            }
            finals.append(.init(id: i, text: item, final: true))
            version += 1
            let segments = cleanedCount > 0 ? Self.cleanup(Array(items[..<finals.count]), count: cleanedCount, joiner: joiner, run: run, version: 0).segments : finals
            rig.queue.enqueue(LiveDictationSnapshot(runID: run, version: version, segments: segments, complete: stops || cleanedCount > 0))
            // A cleanup of the items so far (the late whole pass after a stop): now, or while the next line starts.
            if stops, chance(0.6) { if chance(0.5) { publishCleanup(&rig) } else { pendingCleanup = true } }
        }
        if chance(0.5) { rig.drain() }
        publishCleanup(&rig)
        guard rig.drain(limitMs: 60_000) else { return "no stall: the queue did not drain (text \(rig.field.string.debugDescription))" }
        if rig.field.reorders > 0 || rig.field.staleTriggers > 0 { return "host timing traps: \(rig.field.reorders) reorders, \(rig.field.staleTriggers) stale" }
        let pieces = Self.pieces(items, joiner: joiner)
        let expected = initial + "- " + pieces.joined(separator: "\n- ") + "."
        // Each line holds its own words; the last ends the run. A stopped take's cleanup may have put its period at the
        // end of an earlier line already: a later cleanup that keeps it there leaves it.
        let lines = String(rig.field.string.dropFirst(initial.count)).components(separatedBy: "\n")
        let fits = rig.field.string.hasPrefix(initial) && lines.count == pieces.count && zip(lines, pieces).enumerated().allSatisfy { i, pair in
            pair.0 == "- " + pair.1 + (i == pieces.count - 1 ? "." : "") || (stops && i < pieces.count - 1 && pair.0 == "- " + pair.1 + ".")
        }
        if !fits {
            return "final text \(rig.field.string.debugDescription), expected \(expected.debugDescription) (joiner \(joiner.debugDescription), stops \(stops))"
        }
        if !rig.drops.isEmpty { return "dropped \(rig.drops.map(\.reason.rawValue)) with nothing conflicting" }
        return nil
    }
}

/// SplitMix64: a small, stable generator, so a seed replays the same session on every platform.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct StressSession {
    let seed: UInt64
    private var rng: SeededGenerator
    /// Choices added later draw from here, so earlier seeds replay the same sessions.
    private var extra: SeededGenerator
    /// Late cleanups draw from their own generator (they replace the take's cleanup in some sessions).
    private var late: SeededGenerator
    private let lateCleanups: Bool
    /// Field switches draw from their own generator too (UAT F2).
    private var switches: SeededGenerator
    private let fieldSwitches: Bool
    /// Fields the user left (Safari gives every field of a page one identity: the queue is not told).
    private var retired: [FakeField] = []

    /// `lateCleanups`, `fieldSwitches`: off for the pinned seeds, which replay their sessions as they were when they failed.
    init(seed: UInt64, lateCleanups: Bool = true, fieldSwitches: Bool = true) {
        self.seed = seed; self.lateCleanups = lateCleanups; self.fieldSwitches = fieldSwitches
        rng = SeededGenerator(seed: seed); extra = SeededGenerator(seed: seed ^ 0x57A1E); late = SeededGenerator(seed: seed ^ 0x1A7E)
        switches = SeededGenerator(seed: seed ^ 0xF1E1D)
    }

    /// The user moves to another field of the page with the queue's work for this one pending: an empty field, one that
    /// holds a copy of this field's text (its report pins a place in the queue's model, as in the UAT), or other text.
    private mutating func switchField(_ rig: inout QueueRig) {
        let old = rig.field
        let kind = Int.random(in: 0..<3, using: &switches)
        var text: [Character] = []
        var caret = 0
        // Text the user wrote in both fields (the UAT: the same list line), never the run's own words: a copy of those
        // around the caret is the take itself as far as any keyboard can tell.
        var pieces: [Range<Int>] = []
        var i = 0
        while i < old.text.count {
            guard old.origin[i] != .live else { i += 1; continue }
            let start = i
            while i < old.text.count, old.origin[i] != .live { i += 1 }
            if i - start >= 4 { pieces.append(start..<i) }
        }
        if kind == 1, !pieces.isEmpty {
            let piece = pieces[Int.random(in: 0..<pieces.count, using: &switches)]
            let start = Bool.random(using: &switches) ? piece.lowerBound : Int.random(in: piece.lowerBound..<(piece.upperBound - 2), using: &switches)
            let end = Int.random(in: (start + 1)...piece.upperBound, using: &switches)
            text = Array(old.text[start..<end])
            caret = Bool.random(using: &switches) ? text.count : Int.random(in: 0...text.count, using: &switches)
        } else if kind == 2 {
            text = Array("Dear Anna, the boat is ready.")
            caret = Int.random(in: 0...text.count, using: &switches)
        }
        var field = FakeField(String(text), caret: caret)
        field.lagTicks = old.lagTicks; field.window = old.window; field.blockEcho = old.blockEcho
        field.movesByCharacters = old.movesByCharacters; field.hostDelays = old.hostDelays
        field.staleReportsAfterTap = old.staleReportsAfterTap; field.nowMs = rig.clockMs
        if rig.trace { print("        SWITCH to", String(text).debugDescription, "caret", caret) }
        retired.append(old)
        rig.field = field
        rig.fieldSwitched()
    }

    private mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    private mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &rng)] }

    /// Runs one session; returns what went wrong, or nil.
    mutating func run() -> String? {
        let emoji = chance(0.3)
        var words = ["alpha", "beta", "gamma", "delta", "river", "stone", "light", "table", "green", "quiet", "north", "maple"]
        if emoji { words += ["👍", "café", "🇩🇪"] }
        let blockEcho = chance(0.2)
        var initial = (0..<Int.random(in: 0...6, using: &rng)).map { _ in pick(words) }.joined(separator: " ")
        if blockEcho { initial = "Title\n" + initial }
        let caret = chance(0.5) ? initial.count : (initial.indices.filter { initial[$0] == " " }.randomElement(using: &rng).map { initial.distance(from: initial.startIndex, to: $0) } ?? initial.count)
        var field = FakeField(initial, caret: caret)
        field.lagTicks = Int.random(in: 0...3, using: &rng)
        field.window = Int.random(in: 20...80, using: &rng)
        field.blockEcho = blockEcho
        field.movesByCharacters = emoji && chance(0.7)
        // Safari's measured timing (optimistic moves, edits landing 5–110 ms later, stale reports after a 0-gap edit).
        field.hostDelays = chance(0.7)
        // Drawn apart from the session's generator, so earlier seeds replay the same sessions.
        if field.hostDelays, Bool.random(using: &extra) { field.staleReportsAfterTap = Int.random(in: 1...4, using: &extra) }
        let clean = chance(0.35)
        var rig = QueueRig(field, config: .init(animated: chance(0.5)))
        // The cleanup comes late: after the take is typed and the user edited and moved (real Claude cleanup, ~20 s).
        let lateCleanup = lateCleanups && Double.random(in: 0..<1, using: &late) < 0.4

        var dictated: [String] = []
        var version = 0
        var complete = false
        var keys: [String] = []
        let ticks = Int.random(in: 150...320, using: &rng)
        // A field switch with the run's work for the old field pending (its words, flips, cleanup) in some sessions.
        let switchAt = fieldSwitches && Double.random(in: 0..<1, using: &switches) < 0.25
            ? Int.random(in: (ticks / 4)...(ticks - 10), using: &switches) : nil
        for tick in 0..<ticks {
            if tick == switchAt { switchField(&rig) }
            // Dictation: words arrive, Soniox flips an earlier one now and then, the take ends and is cleaned up.
            var changed = false
            if !complete, chance(0.25) { dictated.append(pick(words)); changed = true }
            if !complete, !dictated.isEmpty, chance(0.05) {
                let i = Int.random(in: 0..<dictated.count, using: &rng)
                dictated[i] = chance(0.5) ? pick(words) : String(dictated[i].dropLast()) + "s"
                changed = true
            }
            if !complete, tick > ticks * 2 / 3, !dictated.isEmpty { complete = true; changed = true }
            if complete, tick == ticks - 20, !dictated.isEmpty, !lateCleanup {
                dictated[0] = dictated[0].prefix(1).uppercased() + dictated[0].dropFirst()
                dictated[dictated.count - 1] += "."
                changed = true
            }
            if changed, !dictated.isEmpty {
                version += 1
                rig.queue.enqueue(snap(version, dictated.joined(separator: " "), complete: complete))
            }
            if !clean { userActs(&rig, &keys) }
            rig.tick()
        }
        var lateFrom: Int?
        if lateCleanup, !dictated.isEmpty {
            // Every raw word is in; the user deletes, moves and taps; then the cleaned take arrives.
            rig.drain(limitMs: 30_000 + 150 * Double(rig.field.text.count))
            if !clean {
                for _ in 0..<Int.random(in: 10...40, using: &late) {
                    let roll = Double.random(in: 0..<1, using: &late)
                    if roll < 0.08 { rig.queue.enqueue(.deleteBackward) }
                    else if roll < 0.13 { rig.queue.enqueue(.move(Int.random(in: -8...8, using: &late))) }
                    else if roll < 0.16 { rig.field.tap(at: Int.random(in: 0...rig.field.text.count, using: &late)); rig.outsidePending = true }
                    rig.tick()
                }
                rig.drain(limitMs: 30_000 + 150 * Double(rig.field.text.count))
            }
            dictated[0] = dictated[0].prefix(1).uppercased() + dictated[0].dropFirst()
            dictated[dictated.count - 1] += "."
            version += 1
            // (Raw words still untyped, out of sight after a resync, start at the cursor as they should.)
            if !rig.queue.hasUntypedRest { lateFrom = rig.events.count }
            rig.queue.enqueue(LiveDictationSnapshot(runID: "r", version: version, segments: [
                .init(id: 0, text: dictated.joined(separator: " "), cleaned: true, final: true),
            ], complete: true))
        }
        // A selection holds dictation and edits (typing would replace it): the user taps it away at the end.
        if rig.field.selection > 0 { rig.field.tap(at: rig.field.caret); rig.outsidePending = true }
        // One grapheme an op, each waiting for the (perhaps lagging) field: the time it may take grows with the text.
        let target = dictated.joined(separator: " ")
        // Late enough that the cleanup is pending for the old field (the UAT's F2).
        if fieldSwitches, switchAt == nil, Double.random(in: 0..<1, using: &switches) < 0.1 { switchField(&rig) }
        let drained = rig.drain(limitMs: 30_000 + 150 * Double(rig.field.text.count + target.count))
        // A cleanup rewrites words already typed: it starts no new region at the user's cursor.
        if let lateFrom, drained, rig.events[lateFrom...].contains(where: { if case .regionStarted = $0.event { true } else { false } }) {
            return "the late cleanup started a region at the user's cursor (text \(rig.field.string.debugDescription))"
        }
        return check(rig, drained: drained, clean: clean, initial: initial, caret: caret, target: target, keys: keys)
    }

    private mutating func userActs(_ rig: inout QueueRig, _ keys: inout [String]) {
        if chance(0.04) { let key = pick(["a", "b", "x", " ", ",", "k"]); keys.append(key); rig.queue.enqueue(.insert(key)) }
        if chance(0.015) { rig.queue.enqueue(.deleteBackward) }
        if chance(0.02) { rig.queue.enqueue(.move(Int.random(in: -6...6, using: &rng))) }
        if chance(0.008) { rig.field.tap(at: Int.random(in: 0...rig.field.text.count, using: &rng)); rig.outsidePending = true }
        if chance(0.004), rig.field.text.count > 4 {
            let start = Int.random(in: 0..<(rig.field.text.count - 3), using: &rng)
            rig.field.select(start..<(start + 3)); rig.outsidePending = true
        }
        if chance(0.004) { rig.field.typeOutside(pick(["Q", "zz", " outside "])); rig.outsidePending = true }
        if chance(0.01) {
            // Magic: the text around the cursor as a read saw it, with one word changed.
            let c = rig.field.caret
            let before = String(rig.field.text[max(0, c - 30)..<c]), after = String(rig.field.text[c..<min(rig.field.text.count, c + 10)])
            let scope = before + after
            if let range = scope.range(of: pick(["alpha", "beta", "river", "stone", "a", "e"])) {
                rig.queue.enqueue(FieldQueue.Edit(kind: .magic, before: before, after: after,
                                                  target: Bool.random(using: &extra) ? scope.uppercased() // a whole-scope rewrite
                                                      : scope.replacingCharacters(in: range, with: "MAGIC"), cursorAtEnd: false, paced: true))
            }
        }
    }

    private func check(_ rig: QueueRig, drained: Bool, clean: Bool, initial: String, caret: Int, target: String, keys: [String]) -> String? {
        guard drained else { return "no stall: the queue did not drain (text \(rig.field.string.debugDescription))" }
        // The host's timing traps: ops landing out of order, a report stuck after an edit right behind a move.
        if rig.field.reorders > 0 { return "\(rig.field.reorders) ops landed out of order (sent too close together)" }
        if rig.field.staleTriggers > 0 { return "\(rig.field.staleTriggers) edits went right behind a move (stale reports)" }
        // One op in flight: a confirmation or a resync between any two ops.
        var open = false
        for (ms, event) in rig.events {
            switch event {
            case .sent: if open { return "two ops in flight at \(Int(ms)) ms" }; open = true
            case .confirmed, .resync: open = false
            default: break
            }
        }
        // The live run only ever deletes what it typed (in the field it typed it into).
        // (A selection or text another keyboard typed is invisible until a late report shows it: an op already on its
        // way can race with it. Once the queue has seen it, nothing is excused.)
        let fields = retired + [rig.field]
        for field in fields {
            if let bad = field.deletions.first(where: { $0.by == .live && $0.origin != .live && !$0.racing }) {
                return "the live run deleted \(String(bad.char).debugDescription) written by \(bad.origin.rawValue)"
            }
        }
        // After a field switch, the run's text goes into the new field only at the user's caret (new words) or next to
        // what it typed there: never its old field's work (a cleanup's jump, a joiner) away from both.
        for field in fields.dropFirst() {
            if field.liveInserts.contains(where: { !$0.atUserCaret && !$0.touchesOwn && !$0.racing }) {
                return "the live run typed into another field away from the caret (text \(field.string.debugDescription))"
            }
        }
        // Every key went out exactly once, at the user's caret.
        let userInserts = rig.events.compactMap { e -> String? in
            if case .sent(.insert(let s), .user) = e.event { return s } else { return nil }
        }
        if userInserts.count != keys.count { return "keys sent \(userInserts.count) of \(keys.count)" }
        for (sent, key) in zip(userInserts, keys) where !sent.hasSuffix(key) { return "key \(key.debugDescription) went out as \(sent.debugDescription)" }
        for field in fields {
            if let miss = field.userInserts.first(where: { $0.caret != $0.userCaret && !$0.racing }), !field.clobberedSelection {
                return "a key landed at \(miss.caret), the user's caret was at \(miss.userCaret)"
            }
        }
        guard clean, retired.isEmpty else { return nil }
        // Nothing conflicted: the field holds exactly the text around the run.
        let chars = Array(initial)
        let before = String(chars[..<caret]), after = String(chars[caret...])
        var typed = DictationTypist.prepare(target, contextBefore: before, capitalization: .none)
        let closing: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "\u{2019}", "\u{201D}"]
        if let next = after.first, !next.isWhitespace, !closing.contains(next), !typed.isEmpty { typed += " " }
        let expected = before + typed + after
        if rig.field.string != expected { return "final text \(rig.field.string.debugDescription), expected \(expected.debugDescription)" }
        if !rig.drops.isEmpty { return "dropped \(rig.drops.map(\.reason.rawValue)) with nothing conflicting" }
        return nil
    }
}
