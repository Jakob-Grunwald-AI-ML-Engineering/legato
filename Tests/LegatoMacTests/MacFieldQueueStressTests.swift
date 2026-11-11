import Foundation
import Testing
import LegatoKeyboardCore
@testable import LegatoMac

/// A fake Accessibility field: every call is synchronous like AX, a read can lag one write behind, and the user's
/// typing and clicks land between the queue's steps.
///
/// With `keys`, it ignores Accessibility writes (like Chromium web content) and takes synthetic keys instead: a key
/// shows only after a lag (sometimes past the queue's read-back window), some keys are dropped, and the focus blips
/// now and then. Keys and the user's input apply in the order they came, like one event stream.
@MainActor private final class FakeAXField: TextTarget {
    var value: [Character] = []
    var selection = UTF16Range(location: 0, length: 0)
    var lagging: String?
    var lagChance = 0.0
    var writes = 0
    var rng: SeededRandom
    init(_ text: String, rng: SeededRandom) { value = Array(text); selection = .init(location: text.utf16.count, length: 0); self.rng = rng }

    // Keystroke mode.
    var keys = false
    var clock: () -> ContinuousClock.Instant = { .now }
    var dropChance = 0.0
    var lateChance = 0.0
    var blipChance = 0.0
    var mark = 0
    var keysSent = 0, keysDropped = 0, keysLate = 0, refusals = 0
    private var inFlight: [(due: ContinuousClock.Instant, key: FieldKey)] = []
    var editsInPlace: Bool { !keys }
    var typesKeys: Bool { keys }
    var inputMark: Int { mark }

    func press(_ key: FieldKey, mark: Int, selection planned: UTF16Range) throws {
        settle()
        guard keys else { throw FieldKeyRefusal.unavailable }
        if rng.chance(blipChance) { refusals += 1; throw FieldKeyRefusal.notFocused }
        guard mark == self.mark else { refusals += 1; throw FieldKeyRefusal.userInput }
        guard planned == selection else { refusals += 1; throw FieldKeyRefusal.selectionMoved }
        if case .text(let character) = key { precondition(!character.isNewline && character != "\t", "Return or Tab synthesized") }
        keysSent += 1
        if rng.chance(dropChance) { keysDropped += 1; return }
        let late = rng.chance(lateChance)
        if late { keysLate += 1 }
        let lag = late ? 450 + rng.next(450) : rng.next(30)
        inFlight.append((clock() + .milliseconds(lag), key))
    }

    /// Keys whose lag passed show now (in order).
    func settle(all: Bool = false) {
        while let first = inFlight.first, all || first.due <= clock() {
            inFlight.removeFirst()
            apply(first.key)
        }
    }
    var keysInFlight: Int { inFlight.count }

    private func offsets() -> [Int] { [0] + value.indices.map { String(value[...$0]).utf16.count } }
    private func apply(_ key: FieldKey) {
        let offsets = offsets()
        let caret = selection.location
        switch key {
        case .left:
            if selection.length > 0 { selection.length = 0 }
            else if let previous = offsets.last(where: { $0 < caret }) { selection = .init(location: previous, length: 0) }
        case .right:
            if selection.length > 0 { selection = .init(location: selection.end, length: 0) }
            else if let next = offsets.first(where: { $0 > caret }) { selection = .init(location: next, length: 0) }
        case .backspace:
            if selection.length > 0 { replaceSelection(with: ""); return }
            guard let previous = offsets.last(where: { $0 < caret }) else { return }
            selection = .init(location: previous, length: caret - previous)
            replaceSelection(with: "")
        case .text(let character):
            replaceSelection(with: String(character))
        }
    }
    private func replaceSelection(with text: String) {
        let ns = string as NSString
        value = Array(ns.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text))
        selection = .init(location: selection.location + text.utf16.count, length: 0)
    }

    var string: String { String(value) }
    func isFocused() -> Bool { true }
    func selectedRange() throws -> UTF16Range { settle(); return selection }
    func textLength() throws -> Int { settle(); return string.utf16.count }
    func text(in range: UTF16Range) throws -> String {
        settle()
        let shown = (lagging ?? string) as NSString
        lagging = nil
        guard range.location >= 0, range.end <= shown.length else { throw TextTargetReadError.unsupported }
        return shown.substring(with: NSRange(location: range.location, length: range.length))
    }
    func setSelectedRange(_ range: UTF16Range) throws {
        guard range.location >= 0, range.end <= string.utf16.count else { throw TextTargetReadError.unsupported }
        selection = range
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        // A Chromium field reports success for an Accessibility write and changes nothing.
        guard !keys else { writes += 1; return }
        let before = string
        let ns = before as NSString
        guard range.location >= 0, range.end <= ns.length else { throw TextTargetReadError.unsupported }
        value = Array(ns.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text))
        selection = .init(location: range.location + text.utf16.count, length: 0)
        writes += 1
        if rng.chance(lagChance) { lagging = before }
    }

    /// The user types `character` at their caret (replacing a selection).
    func type(_ character: Character) {
        settle(all: true); mark += 1
        let ns = string as NSString
        value = Array(ns.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: String(character)))
        selection = .init(location: selection.location + String(character).utf16.count, length: 0)
    }
    /// The user clicks somewhere (on a grapheme boundary).
    func click() {
        settle(all: true); mark += 1
        let offsets = [0] + value.indices.map { String(value[...$0]).utf16.count }
        selection = .init(location: offsets[rng.next(offsets.count)], length: 0)
    }
}

/// SplitMix64: the same seed always plays the same session.
private struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(nextRaw() % UInt64(bound)) }
    mutating func chance(_ p: Double) -> Bool { Double(nextRaw() % 10_000) / 10_000 < p }
}

@MainActor @Suite struct MacFieldQueueStressTests {
    private static let words = ["sail", "north", "wind", "harbor", "tide", "deck", "rope", "calm", "squall", "anchor"]

    /// One seeded session: a run grows word by word with revisions, then its cleanup lands; Magic rewrites a word; the
    /// user types digits and clicks in between; reads lag. Invariants: the queue goes idle, never deletes or changes a
    /// digit the user typed, and when the user never acted the field ends exactly as dictated and edited.
    private struct Stats { var digits = 0, drops = 0, keys = 0, dropped = 0, late = 0, refusals = 0 }

    private func session(seed: UInt64, keys: Bool = false, stats: inout Stats) async -> String? {
        var rng = SeededRandom(seed)
        let field = FakeAXField("Log: ", rng: SeededRandom(seed &* 31))
        field.lagChance = rng.chance(0.5) ? 0.3 : 0
        let interferes = rng.chance(0.7)
        var typedDigits = 0
        var clock = ContinuousClock.now
        if keys {
            field.keys = true
            field.clock = { clock }
            field.dropChance = rng.chance(0.5) ? 0.03 : 0
            field.lateChance = rng.chance(0.5) ? 0.04 : 0
            field.blipChance = 0.02
        }
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        queue.now = { clock }
        var userRng = SeededRandom(seed &+ 7)
        var drops: [MacFieldQueue.Drop] = []
        var trail: [String] = []
        queue.journal = { entry in
            trail.append("\(entry.kind.rawValue) \(entry.location.map(String.init) ?? "") \(entry.text ?? "") \(entry.reason ?? "") \(entry.detail ?? "")")
            if trail.count > 600 { trail.removeFirst() }
        }
        queue.onDrop = { drops.append($0) }
        queue.sleep = { duration in
            clock += duration
            guard interferes else { return }
            // Keys read back every few milliseconds: the user acts at the same rate per time as between paced writes.
            let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            let scale = keys ? min(1, ms / 40) : 1
            if userRng.chance(0.05 * scale) {
                field.type(Character(String(typedDigits % 10))); typedDigits += 1; queue.userActed()
            } else if userRng.chance(0.02 * scale) {
                field.click(); queue.userActed()
            }
        }
        // Dictation: grows, revises a word now and then, ends with a cleanup.
        var spoken: [String] = []
        var version = 0
        for _ in 0..<(3 + rng.next(6)) {
            spoken.append(Self.words[rng.next(Self.words.count)])
            if spoken.count > 1, rng.chance(0.3) { spoken[rng.next(spoken.count - 1)] = Self.words[rng.next(Self.words.count)] }
            version += 1
            queue.live(runID: "run", version: version, text: spoken.joined(separator: " "))
            for _ in 0..<rng.next(20) { await Task.yield() }
        }
        let cleaned = spoken.joined(separator: " ").capitalizedFirst + "."
        version += 1
        queue.live(runID: "run", version: version, text: cleaned)
        await queue.whenIdle()
        // Magic: the first word of the dictation in capitals, from a read of the field as it is now.
        var magicResult: MacFieldQueue.EditResult?
        let text = field.string as NSString
        let word = cleaned.split(separator: " ").first.map(String.init) ?? ""
        let hit = text.range(of: word)
        if hit.location != NSNotFound, !word.isEmpty {
            let before = text.substring(with: NSRange(location: max(0, hit.location - 8), length: min(8, hit.location)))
            magicResult = await queue.edit(.init(range: .init(location: hit.location, length: hit.length), scope: word,
                                                 before: before, target: word.uppercased(), caretAfter: true))
        }
        await queue.whenIdle()
        if field.keysInFlight > 0 { return "seed \(seed): idle with \(field.keysInFlight) keys in flight: \(queue.debugState)" }
        let final = field.string
        stats.digits += typedDigits; stats.drops += drops.count
        stats.keys += field.keysSent; stats.dropped += field.keysDropped; stats.late += field.keysLate; stats.refusals += field.refusals
        if keys, field.writes > 0 { return "seed \(seed): \(field.writes) Accessibility writes to a keystroke field" }
        // Invariants.
        let digits = final.filter(\.isNumber).count
        if digits != typedDigits { return "seed \(seed): \(typedDigits) digits typed, \(digits) left: \(final)" }
        // The fake never loses focus: a park-and-drop means the queue could not make progress.
        if drops.contains(where: { $0.reason == .focusLost || $0.reason == .failed }) {
            return "seed \(seed): stalled: \(drops) state=\(queue.debugState) final=\(final)\n\(trail.joined(separator: "\n"))"
        }
        if queue.hasWork { return "seed \(seed): still busy: \(queue.debugState)\n\(trail.joined(separator: "\n"))" }
        if !interferes, field.lagChance == 0 || keys {
            let expected = "Log: " + cleaned.replacingOccurrences(of: word, with: word.uppercased(), options: [], range: cleaned.range(of: word))
            if final != expected { return "seed \(seed): \(final) != \(expected) drops=\(drops) state=\(queue.debugState)\n\(trail.joined(separator: "\n"))" }
        }
        if case .applied(let range)? = magicResult, (final as NSString).substring(with: NSRange(location: range.location, length: range.length)) != word.uppercased() {
            // The user may have typed inside the result after it landed; only a result that was never placed is wrong.
            if !interferes { return "seed \(seed): Magic reported \(range) but the field shows \(final)" }
        }
        // Keys leave the caret where the user expects it: after Magic's result.
        if keys, !interferes, case .applied(let range)? = magicResult, field.selection != UTF16Range(location: range.end, length: 0) {
            return "seed \(seed): caret \(field.selection) after Magic's result \(range): \(final)\n\(trail.joined(separator: "\n"))"
        }
        return nil
    }

    @Test func seededSessionsKeepTheUsersTextAndAlwaysFinish() async {
        let runs = Int(ProcessInfo.processInfo.environment["LEGATO_STRESS_RUNS"] ?? "") ?? 150
        let only = ProcessInfo.processInfo.environment["LEGATO_STRESS_SEED"].flatMap(UInt64.init)
        var failures: [String] = []
        var stats = Stats()
        for seed in only.map({ [$0] }) ?? (1...UInt64(runs)).map({ $0 }) {
            if let failure = await session(seed: seed, stats: &stats) { failures.append(failure) }
            if failures.count >= 3 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        // The sessions really interfered: the user typed, and some work met text the user changed.
        if only == nil { #expect(stats.digits > runs, "stats: \(stats)") }
    }

    /// The same sessions in a field that ignores Accessibility writes and takes verified keys (Chromium): keys lag,
    /// some land past the read-back window, some are dropped, the focus blips. The same invariants hold, the caret
    /// ends after Magic's result, and no key is left in flight.
    @Test func seededKeystrokeSessionsKeepTheUsersTextAndAlwaysFinish() async {
        let runs = Int(ProcessInfo.processInfo.environment["LEGATO_STRESS_RUNS"] ?? "") ?? 150
        let only = ProcessInfo.processInfo.environment["LEGATO_STRESS_SEED"].flatMap(UInt64.init)
        var failures: [String] = []
        var stats = Stats()
        for seed in only.map({ [$0] }) ?? (1...UInt64(runs)).map({ $0 }) {
            if let failure = await session(seed: seed, keys: true, stats: &stats) { failures.append(failure) }
            if failures.count >= 3 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        if only == nil {
            #expect(stats.digits > runs && stats.dropped > 0 && stats.late > 0 && stats.refusals > 0, "stats: \(stats)")
        }
    }

    @Test func aRevisionAwayFromTheCaretIsAJumpUnitThatReturnsTheCaret() async {
        let field = FakeAXField("", rng: SeededRandom(1))
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.sleep = { _ in }
        queue.live(runID: "r", version: 1, text: "the cab is here")
        await queue.whenIdle()
        // The user clicks to the start and types; then the recognizer revises "cab".
        field.selection = .init(location: 0, length: 0); field.type("9"); queue.userActed()
        let writes = field.writes
        queue.live(runID: "r", version: 2, text: "the cat is here")
        await queue.whenIdle()
        #expect(field.string == "9the cat is here")
        #expect(field.selection == .init(location: 1, length: 0))
        // Only the differing characters were rewritten.
        #expect(field.writes - writes == 1)
    }

    @Test func aKeystrokeFieldRevisesAwayFromTheCaretWithKeysAndReturnsTheCaret() async {
        let field = FakeAXField("", rng: SeededRandom(3))
        field.keys = true
        var clock = ContinuousClock.now
        field.clock = { clock }
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.sleep = { clock += $0 }
        queue.now = { clock }
        queue.live(runID: "r", version: 1, text: "the cab is here")
        await queue.whenIdle()
        field.settle(all: true)
        #expect(field.string == "the cab is here")
        field.selection = .init(location: 0, length: 0); field.type("9"); queue.userActed()
        let sent = field.keysSent
        queue.live(runID: "r", version: 2, text: "the cat is here")
        await queue.whenIdle()
        #expect(field.string == "9the cat is here")
        #expect(field.selection == .init(location: 1, length: 0))
        // Arrows to the end of "cab", one Backspace, "t", arrows back: no Accessibility write.
        #expect(field.writes == 0)
        #expect(field.keysSent - sent == 7 + 2 + 7)
    }

    @Test func pacedInsertsGoOneGraphemeAtATimeAndAFlushSendsTheRestWhole() async {
        let field = FakeAXField("", rng: SeededRandom(2))
        let queue = MacFieldQueue(target: field)
        var ticks = 0
        queue.sleep = { _ in ticks += 1 }
        queue.live(runID: "r", version: 1, text: "ab⛵️")
        await queue.whenIdle()
        #expect(field.string == "ab⛵️")
        #expect(field.writes == 3)
        queue.live(runID: "r", version: 2, text: "ab⛵️ cd ef")
        await queue.flush()
        #expect(field.string == "ab⛵️ cd ef")
        #expect(field.writes == 4)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
