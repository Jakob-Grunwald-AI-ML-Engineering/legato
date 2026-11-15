import Foundation
import Testing
@testable import LegatoKeyboardCore

/// Seeded takes against a misbehaving field (short windows, lag, truncated reports, Safari's timing and block echo),
/// shaped like the app's live publications: a speaking head that grows, flips its last words and now and then an earlier
/// one, re-splits into finals, segments joined at punctuation (", like"), fillers the cleanup removes, long takes (many
/// times the window). Some sessions the user leaves alone; in others they type, delete, move or tap during the take or
/// after its stop. Invariants: one op in flight, no host timing traps, dictation never deletes or moves over text from
/// before the user's last action (nor anyone else's text), the keyboard makes no delete or move once the user acted
/// (an op already on its way aside), every key lands once at the user's caret and no user character is lost, no word of
/// the take stands more often than any version had it, an untouched take ends exactly as its cleaned text with nothing
/// reported (unless the report at the stop did not show the take's end as typed: it is kept and reported, counted
/// apart), and a touched one either shows its cleaned text or is reported (`Event.dropped`, History).
/// `LEGATO_STRESS_RUNS` sets the seed count, `LEGATO_STRESS_SEED` replays one, `LEGATO_STRESS_TRACE=1` traces.
@Suite struct FieldQueueTakeStressTests {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    @Test func seededTakesKeepTheInvariants() {
        let runs = Self.environment["LEGATO_STRESS_RUNS"].flatMap(Int.init) ?? 48
        let first = (Self.environment["LEGATO_STRESS_SEED"] ?? Self.environment["LEGATO_STRESS_FIRST"]).flatMap(UInt64.init) ?? 1
        var outcomes: [String: Int] = [:]
        var failures = 0
        for i in 0..<(Self.environment["LEGATO_STRESS_SEED"] == nil ? runs : 1) {
            let seed = first &+ UInt64(i)
            if Self.environment["LEGATO_STRESS_PROGRESS"] == "1" { print("take seed \(seed)") }
            var session = TakeSession(seed: seed)
            if let failure = session.run() {
                Issue.record("take seed \(seed) (replay: LEGATO_STRESS_SEED=\(seed)): \(failure)")
                outcomes["failed", default: 0] += 1
                failures += 1
                if failures >= 5 { break }
            } else {
                outcomes[session.outcome, default: 0] += 1
            }
        }
        print("take stress outcomes:", outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
}

struct TakeSession {
    let seed: UInt64
    private var rng: SeededGenerator
    private(set) var outcome = ""
    /// Revisions of a word already published (and likely typed) draw from their own generator.
    private var heard: SeededGenerator
    init(seed: UInt64) { self.seed = seed; rng = SeededGenerator(seed: seed ^ 0x7A4E5); heard = SeededGenerator(seed: seed ^ 0x4EA7D) }

    private mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    private mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &rng)] }
    private mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }

    private static let words = ["boat", "harbour", "early", "wind", "west", "anchor", "chart", "north", "tide", "sail", "crew",
                                "morning", "river", "stone", "light", "table", "green", "quiet", "maple", "coffee", "ready"]
    private static let fillers = ["um", "uh"]

    /// The app's cleanup of the take's raw segments: fillers out, the first letter up, a period at the end.
    static func cleaned(_ raw: String) -> String {
        var words = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        words.removeAll { fillers.contains($0.trimmingCharacters(in: .punctuationCharacters)) }
        var text = words.joined(separator: " ")
        text = text.replacingOccurrences(of: " ,", with: ",")
        while text.hasPrefix(",") || text.hasPrefix(" ") { text.removeFirst() }
        guard let first = text.first else { return "" }
        text = first.uppercased() + text.dropFirst()
        if let last = text.last, !".?!".contains(last) {
            if ",;:".contains(last) { text.removeLast() }
            text += "."
        }
        return text
    }

    mutating func run() -> String? {
        // The field.
        let initialWords = (0..<int(0...5)).map { _ in pick(["Dear", "crew,", "note", "list:", "fine", "alpha"]) }
        let blockEcho = chance(0.2)
        var initial = initialWords.joined(separator: " ")
        if blockEcho { initial = "Title\n" + initial }
        if !initial.isEmpty, chance(0.7) { initial += " " }
        let midField = chance(0.2) && !initial.isEmpty
        let caret = midField ? (initial.lastIndex(of: " ").map { initial.distance(from: initial.startIndex, to: $0) } ?? initial.count) : initial.count
        var field = FakeField(initial, caret: caret)
        field.window = pick([20, 30, 45, 60, 80, 120])
        field.lagTicks = int(0...2)
        field.hostDelays = chance(0.7)
        field.blockEcho = blockEcho
        field.truncation = chance(0.4) ? Double(int(2...20)) / 100 : 0
        field.truncationRng = SeededGenerator(seed: seed ^ 0x7C)
        field.rng = SeededGenerator(seed: seed ^ 0xD1)
        var rig = QueueRig(field, config: .init(animated: chance(0.7), prioritizeSpeech: true))

        // The user: left alone, acting during the take, after its stop, or both.
        let mode = pick(["alone", "alone", "alone", "during", "during", "after", "both"])
        let actsDuring = mode == "during" || mode == "both", actsAfter = mode == "after" || mode == "both"
        var keys: [String] = []
        var acted = false
        // The words spoken since the user's last action (new speech, not a revision of a published word): every one the
        // take still has at the end reaches the field once.
        var newWords: [String] = []
        func spokenWord(_ word: String) -> String? {
            word.split { !($0.isLetter || $0.isNumber) }.map(String.init).first { $0.hasSuffix("q") && $0.dropLast().last?.isNumber == true }
        }

        // The take: words in segments, joints at punctuation, fillers, Soniox flips of the head. Most sessions speak every
        // word once (a word standing twice in the field is then a duplicate); the others repeat words freely.
        let unique = chance(0.7)
        var serial = 0
        func next(_ rng: inout SeededGenerator) -> String {
            serial += 1
            let base = Self.words[Int.random(in: 0..<Self.words.count, using: &rng)]
            // A serial number, and "q" to end it: a word cut short (a key, a tap) is never another whole word.
            return unique ? base + String(serial) + "q" : base
        }
        let total = pick([6, 12, 25, 40, 80, 120])
        var finals: [String] = []
        var head: [String] = []
        var version = 0
        func publish(_ snapshot: LiveDictationSnapshot, _ rig: inout QueueRig) {
            if rig.trace { print("        PUBLISH", snapshot.version, FieldQueue.target(of: snapshot).debugDescription) }
            rig.queue.enqueue(snapshot)
        }
        func speaking(_ finals: [String], _ head: [String], stopped: Bool = false) -> LiveDictationSnapshot {
            version += 1
            var segments = finals.enumerated().map { LiveSegment(id: $0.offset, text: $0.element, final: true) }
            if !head.isEmpty { segments.append(LiveSegment(id: finals.count, text: head.joined(separator: " "), final: false)) }
            return LiveDictationSnapshot(runID: "t", version: version, segments: segments, stopped: stopped ? true : nil)
        }
        var spoken = 0
        while spoken < total {
            var word = next(&rng)
            if chance(0.08) { word = pick(Self.fillers) + "," }
            // A segment starting at punctuation (Soniox splits "from" | ", like").
            if head.isEmpty, !finals.isEmpty, chance(0.25) { word = pick([",", ".", ";", "—"]) + " " + word }
            head.append(word); spoken += 1
            // Soniox flips the head's last word, sometimes one further back.
            if head.count > 1, chance(0.12) { head[head.count - 1] = next(&rng) }
            if let w = spokenWord(head[head.count - 1]) { newWords.append(w) }
            if head.count > 4, chance(0.04) {
                let i = int(0...(head.count - 3))
                newWords.removeAll { $0 == spokenWord(head[i]) }
                head[i] = next(&rng)
            }
            publish(speaking(finals, head), &rig)
            // The head becomes final: whole, or re-split (a short final, the rest a new head).
            if head.count >= 3, chance(0.3) {
                if chance(0.3), head.count > 2 {
                    let k = int(1...(head.count - 1))
                    finals.append(head[..<k].joined(separator: " ")); head = Array(head[k...])
                } else {
                    finals.append(head.joined(separator: " ")); head = []
                }
                publish(speaking(finals, head), &rig)
            }
            let pause = Double(int(120...450))
            var waited = 0.0
            while waited < pause {
                if actsDuring, chance(0.01) { act(&rig, &keys); acted = true; newWords = [] }
                rig.tick(); waited += rig.tickMs
            }
            // The head's last word, published (and likely typed), is heard again as another ("whether" → "weather").
            if unique, !head.isEmpty, Double.random(in: 0..<1, using: &heard) < 0.1 {
                newWords.removeAll { $0 == spokenWord(head[head.count - 1]) }
                head[head.count - 1] = next(&heard)
                publish(speaking(finals, head), &rig)
                rig.run(ms: Double(Int.random(in: 60...300, using: &heard)))
            }
        }
        if !head.isEmpty { finals.append(head.joined(separator: " ")); head = [] }
        // The stop: by the mic key or the snapshot, then the take completes (raw), then its cleanup.
        if chance(0.5) { rig.queue.takeStopped("t") } else { publish(speaking(finals, [], stopped: true), &rig) }
        rig.run(ms: Double(int(0...600)))
        version += 1
        publish(LiveDictationSnapshot(runID: "t", version: version, segments: finals.enumerated().map {
            LiveSegment(id: $0.offset, text: $0.element, final: true) }, complete: true), &rig)
        if actsAfter {
            rig.run(ms: Double(int(0...800)))
            act(&rig, &keys); acted = true; newWords = []
        }
        rig.run(ms: Double(int(0...1_500)))
        let raw = FieldQueue.joined(finals.map { LiveSegment(id: 0, text: $0, final: true) })
        let clean = Self.cleaned(raw)
        version += 1
        let segments: [LiveSegment] = finals.count == 1
            ? [LiveSegment(id: 0, text: clean, cleaned: true, final: true)]
            : finals.enumerated().map { LiveSegment(id: $0.offset, text: $0.offset == 0 ? clean : "", cleaned: true, final: true, unit: 0, raw: $0.element) }
        publish(LiveDictationSnapshot(runID: "t", version: version, segments: segments, complete: true), &rig)
        if rig.field.selection > 0 { rig.field.tap(at: rig.field.caret); rig.outsidePending = true; acted = true }
        let drained = rig.drain(limitMs: 60_000 + 200 * Double(rig.field.text.count + clean.count))
        return check(rig, drained: drained, acted: acted, initial: initial, caret: caret, raw: raw, clean: clean,
                     keys: keys, unique: unique, newWords: newWords)
    }

    private mutating func act(_ rig: inout QueueRig, _ keys: inout [String]) {
        let roll = Double.random(in: 0..<1, using: &rng)
        if rig.trace { print("        ACT", roll, "field", rig.field.string.debugDescription, "caret", rig.field.caret) }
        if roll < 0.45 { let key = pick(["a", "x", " ", ",", "\n"]); keys.append(key); rig.queue.enqueue(.insert(key)) }
        else if roll < 0.6 { rig.queue.enqueue(.deleteBackward) }
        else if roll < 0.8 { rig.queue.enqueue(.move(int(-12...4))) }
        else { rig.field.tap(at: int(0...rig.field.text.count)); rig.outsidePending = true }
    }

    private mutating func check(_ rig: QueueRig, drained: Bool, acted: Bool, initial: String, caret: Int, raw: String, clean: String,
                                keys: [String], unique: Bool, newWords: [String]) -> String? {
        guard drained else { return "no stall: the queue did not drain (text \(rig.field.string.debugDescription))" }
        if rig.field.reorders > 0 { return "\(rig.field.reorders) ops landed out of order" }
        if rig.field.staleTriggers > 0 { return "\(rig.field.staleTriggers) edits went right behind a move" }
        var open = false
        for (ms, event) in rig.events {
            switch event {
            case .sent: if open { return "two ops in flight at \(Int(ms)) ms" }; open = true
            case .confirmed, .resync: open = false
            default: break
            }
        }
        if let bad = rig.field.deletions.first(where: { ($0.by == .live || $0.by == .edit) && $0.origin != .live && !$0.racing }) {
            return "the keyboard (\(bad.by.rawValue)) deleted \(String(bad.char).debugDescription) written by \(bad.origin.rawValue)"
        }
        if let frozen = rig.field.frozenEdits.first { return "dictation edited after the user acted: \(frozen) (text \(rig.field.string.debugDescription))" }
        if let edit = rig.field.ownEditsAfterUser.first {
            return "the keyboard (\(edit.writer.rawValue)) made a \(edit.what) after the user acted (text \(rig.field.string.debugDescription))"
        }
        // A long delete is only the stop's swap: its insert follows at once, unless a tap raced with the delete (the
        // insert then does not go where the take was not seen to go, and the take is reported).
        let live = rig.events.compactMap { if case .sent(let op, .live) = $0.event { op } else { nil } }
        let reportedTake = rig.drops.contains { $0.runID == "t" && $0.reason != .reset }
        for (i, op) in live.enumerated() {
            guard case .deleteBackward(let n) = op, n > FieldQueue.nearChars else { continue }
            guard i + 1 < live.count, case .insert = live[i + 1] else {
                if reportedTake, rig.field.deletions.contains(where: { $0.by == .live && $0.racing }) { continue }
                return "a delete of \(n) characters without the swap's insert"
            }
        }
        let userInserts = rig.events.compactMap { e -> String? in if case .sent(.insert(let s), .user) = e.event { s } else { nil } }
        if userInserts.count != keys.count { return "keys sent \(userInserts.count) of \(keys.count)" }
        if let miss = rig.field.userInserts.first(where: { $0.caret != $0.userCaret && !$0.racing }), !rig.field.clobberedSelection {
            return "a key landed at \(miss.caret), the user's caret was at \(miss.userCaret)"
        }
        // Every word was spoken once: none of the dictation's own (whole, its letters only) stands twice. An insert racing
        // with a tap may land at the tap, which no keyboard can tell.
        if unique {
            var counts: [String: Int] = [:], word = "", whole = true
            let text = rig.field.text, origin = rig.field.origin
            for i in 0...text.count {
                if i < text.count, text[i].isLetter || text[i].isNumber {
                    word.append(text[i]); whole = whole && origin[i] == .live && !rig.field.raced[i]
                } else {
                    if whole, word.hasSuffix("q"), word.first?.isLetter == true, word.dropLast().last?.isNumber == true {
                        counts[word.lowercased(), default: 0] += 1
                    }
                    word = ""; whole = true
                }
            }
            if let twice = counts.first(where: { $0.value > 1 }) {
                return "\(twice.key.debugDescription) stands \(twice.value) times (text \(rig.field.string.debugDescription), raw \(raw.debugDescription))"
            }
            // Every word spoken after the user's last action that the take still has reaches the field, once (the take is
            // typed on at the caret, whatever was revised before).
            if acted {
                let fieldWords = rig.field.string.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
                let rawWords = Set(raw.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
                for word in newWords where rawWords.contains(word.lowercased()) {
                    var n = fieldWords.filter { $0 == word.lowercased() }.count
                    // An insert racing with a tap lands where the user tapped, maybe inside a word: there it stands
                    // glued to the user's text (no keyboard can tell).
                    if n == 0, let at = rig.field.string.lowercased().range(of: word.lowercased()) {
                        let i = rig.field.string.lowercased().distance(from: rig.field.string.lowercased().startIndex, to: at.lowerBound)
                        if rig.field.raced[i..<(i + word.count)].contains(true) { n = 1 }
                    }
                    if n != 1 { return "\(word.debugDescription), spoken after the user acted, stands \(n) times (text \(rig.field.string.debugDescription))" }
                }
            }
        }
        let reported = rig.drops.contains { $0.runID == "t" && $0.reason != .reset }
        let chars = Array(initial)
        let before = String(chars[..<caret]), after = String(chars[caret...])
        var typed = FieldInsertion.prepare(clean, contextBefore: before, capitalization: .none)
        let closing: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "%", "…", "\u{2019}", "\u{201D}"]
        if let next = after.first, !next.isWhitespace, !closing.contains(next), !typed.isEmpty { typed += " " }
        // The field contradicted the queue's model with nobody acting (the model was wrong: Safari's block echo reads a
        // space after a line break as its own): the take may be kept, but then it is reported.
        let contradicted = rig.events.contains { $0.event == .resync(.reseeded) }
        if !acted, contradicted, rig.field.string != before + typed + after {
            guard reported else { return "contradicted take neither cleaned nor reported (text \(rig.field.string.debugDescription))" }
            outcome = "untouched-kept+reported(field contradicted the model)"
            return nil
        }
        // The report at the stop did not show the take's end as the model has it: kept as typed, and reported.
        if !acted, rig.events.contains(where: { $0.event == .resync(.swapRefused) }), rig.field.string != before + typed + after {
            guard reported else { return "take kept at the stop without a report (text \(rig.field.string.debugDescription))" }
            outcome = "untouched-kept+reported(tail not shown)"
            return nil
        }
        if !acted {
            if rig.field.string != before + typed + after {
                let tail = rig.events.suffix(14).map { "\($0.event)".replacingOccurrences(of: "LegatoKeyboardCore.", with: "") }
                return "untouched take: final text \(rig.field.string.debugDescription), expected \(String(before + typed + after).debugDescription) "
                    + "drops \(rig.drops.map(\.reason.rawValue)) state \(rig.queue.debugState) events \(tail)"
            }
            if reported { return "untouched take reported \(rig.drops.map(\.reason.rawValue))" }
            outcome = "untouched-cleaned"
            return nil
        }
        if rig.field.string.contains(typed.trimmingCharacters(in: .whitespaces)) { outcome = "touched-cleaned"; return nil }
        guard reported else { return "touched take neither cleaned nor reported (text \(rig.field.string.debugDescription), cleaned \(clean.debugDescription))" }
        outcome = "touched-kept+reported"
        return nil
    }
}
