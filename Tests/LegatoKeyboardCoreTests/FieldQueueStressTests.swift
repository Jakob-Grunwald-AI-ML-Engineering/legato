import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Seeded random sessions against a misbehaving field: late reports, short windows, Safari's block echo, emoji that
/// move as one unit; dictation that grows, flips and gets cleaned up; the user's keys, deletes, cursor moves, taps,
/// selections and outside typing; Magic edits. CI runs a few dozen seeds; `LEGATO_STRESS_RUNS=5000` runs a long
/// local pass, and `LEGATO_STRESS_SEED=<n>` replays one seed.
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
    @Test(arguments: [UInt64(69), 190, 230, 241, 265, 398, 548, 615, 856, 1035, 1121, 1138, 1376, 1392, 1615, 2251, 2729, 2989, 3569, 4568])
    func pinnedSeedsKeepTheInvariants(seed: UInt64) {
        var session = StressSession(seed: seed)
        if let failure = session.run() { Issue.record("seed \(seed): \(failure)") }
    }

    @Test func seededSessionsKeepTheInvariants() {
        let runs = Self.environment["LEGATO_STRESS_RUNS"].flatMap(Int.init) ?? 48
        let first = Self.environment["LEGATO_STRESS_SEED"].flatMap(UInt64.init) ?? 1
        var failures = 0
        for i in 0..<(Self.environment["LEGATO_STRESS_SEED"] == nil ? runs : 1) {
            let seed = first &+ UInt64(i)
            var session = StressSession(seed: seed)
            if let failure = session.run() {
                Issue.record("seed \(seed) (replay: LEGATO_STRESS_SEED=\(seed)): \(failure)")
                failures += 1
                if failures >= 5 { break }
            }
        }
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

    init(seed: UInt64) { self.seed = seed; rng = SeededGenerator(seed: seed) }

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
        var extra = SeededGenerator(seed: seed ^ 0x57A1E)
        if field.hostDelays, Bool.random(using: &extra) { field.staleReportsAfterTap = Int.random(in: 1...4, using: &extra) }
        let clean = chance(0.35)
        var rig = QueueRig(field, config: .init(animated: chance(0.5)))

        var dictated: [String] = []
        var version = 0
        var complete = false
        var keys: [String] = []
        let ticks = Int.random(in: 150...320, using: &rng)
        for tick in 0..<ticks {
            // Dictation: words arrive, Soniox flips an earlier one now and then, the take ends and is cleaned up.
            var changed = false
            if !complete, chance(0.25) { dictated.append(pick(words)); changed = true }
            if !complete, !dictated.isEmpty, chance(0.05) {
                let i = Int.random(in: 0..<dictated.count, using: &rng)
                dictated[i] = chance(0.5) ? pick(words) : String(dictated[i].dropLast()) + "s"
                changed = true
            }
            if !complete, tick > ticks * 2 / 3, !dictated.isEmpty { complete = true; changed = true }
            if complete, tick == ticks - 20, !dictated.isEmpty {
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
        // A selection holds dictation and edits (typing would replace it): the user taps it away at the end.
        if rig.field.selection > 0 { rig.field.tap(at: rig.field.caret); rig.outsidePending = true }
        let drained = rig.drain(limitMs: 30_000 + 100 * Double(rig.field.text.count))
        return check(rig, drained: drained, clean: clean, initial: initial, caret: caret, target: dictated.joined(separator: " "), keys: keys)
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
                                                  target: scope.replacingCharacters(in: range, with: "MAGIC"), cursorAtEnd: false, paced: true))
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
        // The live run only ever deletes what it typed.
        // (A selection or text another keyboard typed is invisible until a late report shows it: an op already on its
        // way can race with it. Once the queue has seen it, nothing is excused.)
        if let bad = rig.field.deletions.first(where: { $0.by == .live && $0.origin != .live && !$0.racing }) {
            return "the live run deleted \(String(bad.char).debugDescription) written by \(bad.origin.rawValue)"
        }
        // Every key went out exactly once, at the user's caret.
        let userInserts = rig.events.compactMap { e -> String? in
            if case .sent(.insert(let s), .user) = e.event { return s } else { return nil }
        }
        if userInserts.count != keys.count { return "keys sent \(userInserts.count) of \(keys.count)" }
        for (sent, key) in zip(userInserts, keys) where !sent.hasSuffix(key) { return "key \(key.debugDescription) went out as \(sent.debugDescription)" }
        if let miss = rig.field.userInserts.first(where: { $0.caret != $0.userCaret && !$0.racing }) {
            return "a key landed at \(miss.caret), the user's caret was at \(miss.userCaret)"
        }
        guard clean else { return nil }
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
