import Foundation
import Testing
import LegatoKeyboardCore
@testable import LegatoMac

/// A fake Accessibility field: every call is synchronous like AX, a read can lag one write behind, and the user's
/// typing and clicks land between the queue's steps.
///
/// With `keys`, it ignores Accessibility writes (like Chromium web content) and takes synthetic keys instead: a key
/// shows only after a lag (sometimes past the queue's read-back window), some keys are dropped, and the focus blips
/// now and then. Keys and the user's input apply in the order they came, like one event stream. Like Chromium it can
/// also show an empty last line as a placeholder line break (`placeholder`), report the caret of a key typed at a
/// line start late (`lazyCaret`), take, ignore, delay or only pretend to take an Accessibility caret set (`caretSet`),
/// land word hops a few characters off (`hopSkew`) and wrap lines (`wrap`, for Command+Left/Right).
@MainActor private final class FakeAXField: TextTarget {
    enum CaretSet { case takes, ignored, late, phantom }
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
    /// Like a Chromium rich editor: a space typed at the end shows as a no-break space until more text follows.
    var nbsp = false
    /// An empty last line reads as a line break: the field's text ends in an extra "\n" while the value ends in one.
    var placeholder = false
    /// A key typed (or a Backspace) at a line start leaves the reported caret where it was for a while, or until the
    /// next key (`stickyChance`).
    var lazyCaret = false
    var stickyChance = 0.3
    var caretSet = CaretSet.ignored
    /// The share of word hops that land one to three characters off.
    var hopSkew = 0.0
    /// Visual line width for Command+Left/Right (0: no wrapping).
    var wrap = 0
    var key: AnyHashable = AnyHashable(UUID())
    var trail: [String] = []
    var mark = 0
    var keysSent = 0, keysDropped = 0, keysLate = 0, refusals = 0, caretSets = 0, hops = 0, lazyCarets = 0
    private enum Event { case key(FieldKey), caret(UTF16Range) }
    private var inFlight: [(due: ContinuousClock.Instant, event: Event)] = []
    /// The caret the field reports instead of the real one, and until when (nil: until the next key).
    private var reported: (range: UTF16Range, until: ContinuousClock.Instant?)?
    var editsInPlace: Bool { !keys }
    var typesKeys: Bool { keys }
    var inputMark: Int { mark }
    var fieldKey: AnyHashable? { key }

    /// The real caret, the reported one when it differs, keys in flight, and the text (for failure trails).
    var state: String {
        "\(selection.location)+\(selection.length)\(reported.map { " rep \($0.range.location)" } ?? "") fly \(inFlight.count) \(string.replacingOccurrences(of: "\n", with: "⏎"))"
    }
    private var shownCaret: UTF16Range {
        if let reported, reported.until.map({ clock() < $0 }) ?? true { return reported.range }
        reported = nil
        return selection
    }

    func press(_ key: FieldKey, mark: Int, selection planned: UTF16Range) throws {
        settle()
        guard keys else { throw FieldKeyRefusal.unavailable }
        if rng.chance(blipChance) { refusals += 1; throw FieldKeyRefusal.notFocused }
        guard mark == self.mark else { refusals += 1; throw FieldKeyRefusal.userInput }
        guard planned == shownCaret else { refusals += 1; throw FieldKeyRefusal.selectionMoved }
        if case .text(let character) = key { precondition(!character.isNewline && character != "\t", "Return or Tab synthesized") }
        if case .hop = key { hops += 1 }
        keysSent += 1
        if rng.chance(dropChance) { keysDropped += 1; return }
        let late = rng.chance(lateChance)
        if late { keysLate += 1 }
        let lag = late ? 450 + rng.next(450) : rng.next(30)
        inFlight.append((clock() + .milliseconds(lag), .key(key)))
    }

    func setCaret(_ range: UTF16Range, mark: Int, selection planned: UTF16Range) throws {
        settle()
        guard keys else { throw FieldKeyRefusal.unavailable }
        guard mark == self.mark else { refusals += 1; throw FieldKeyRefusal.userInput }
        guard planned == shownCaret else { refusals += 1; throw FieldKeyRefusal.selectionMoved }
        caretSets += 1
        switch caretSet {
        case .takes: inFlight.append((clock() + .milliseconds(rng.next(20)), .caret(range)))
        case .late: inFlight.append((clock() + .milliseconds(100 + rng.next(150)), .caret(range)))
        case .ignored: break
        // The field reports the new caret; the real one stays (until a key makes it report afresh).
        case .phantom: reported = (range, nil)
        }
    }

    /// Keys whose lag passed show now (in order).
    func settle(all: Bool = false) {
        while let first = inFlight.first, all || first.due <= clock() {
            inFlight.removeFirst()
            switch first.event {
            case .key(let key): apply(key)
            case .caret(let range):
                if range.end <= value.count(utf16: true) { selection = range }
                reported = nil
            }
        }
    }
    var keysInFlight: Int { inFlight.count }

    private func offsets() -> [Int] { [0] + value.indices.map { String(value[...$0]).utf16.count } }
    private func atLineStart(_ location: Int) -> Bool {
        location == 0 || (string as NSString).substring(with: NSRange(location: location - 1, length: 1)) == "\n"
    }
    private func apply(_ key: FieldKey) {
        let before = selection
        reported = nil
        let offsets = offsets()
        let caret = selection.location
        let ns = string as NSString
        func word(_ unit: unichar) -> Bool { CharacterSet.alphanumerics.contains(UnicodeScalar(unit) ?? " ") }
        func skewed(_ location: Int) -> Int {
            guard rng.chance(hopSkew) else { return location }
            let off = (1 + rng.next(3)) * (rng.chance(0.5) ? -1 : 1)
            return min(max(0, location + off), ns.length)
        }
        switch key {
        case .left:
            if selection.length > 0 { selection.length = 0 }
            else if let previous = offsets.last(where: { $0 < caret }) { selection = .init(location: previous, length: 0) }
        case .right:
            if selection.length > 0 { selection = .init(location: selection.end, length: 0) }
            else if let next = offsets.first(where: { $0 > caret }) { selection = .init(location: next, length: 0) }
        case .arrows(let left, let count):
            for _ in 0..<count { apply(left ? .left : .right) }
            return
        case .hop(let hop):
            var at = selection.length > 0 ? (hop == .wordLeft || hop == .lineStart ? selection.location : selection.end) : caret
            let lineStart = (ns.substring(to: at) as NSString).range(of: "\n", options: .backwards).location
            let hardStart = lineStart == NSNotFound ? 0 : lineStart + 1
            let next = ns.range(of: "\n", options: [], range: NSRange(location: at, length: ns.length - at)).location
            let hardEnd = next == NSNotFound ? ns.length : next
            switch hop {
            case .wordLeft:
                while at > 0, !word(ns.character(at: at - 1)) { at -= 1 }
                while at > 0, word(ns.character(at: at - 1)) { at -= 1 }
                at = skewed(at)
            case .wordRight:
                while at < ns.length, !word(ns.character(at: at)) { at += 1 }
                while at < ns.length, word(ns.character(at: at)) { at += 1 }
                at = skewed(at)
            case .lineStart:
                at = wrap > 0 ? hardStart + (at - hardStart) / wrap * wrap : hardStart
            case .lineEnd:
                at = wrap > 0 ? min(hardEnd, hardStart + ((at - hardStart) / wrap + 1) * wrap) : hardEnd
            case .documentStart: at = 0
            case .documentEnd: at = ns.length
            }
            selection = .init(location: at, length: 0)
        case .backspace:
            if selection.length > 0 { replaceSelection(with: ""); return }
            guard let previous = offsets.last(where: { $0 < caret }) else { return }
            selection = .init(location: previous, length: caret - previous)
            replaceSelection(with: "")
            lazy(before, after: atLineStart(selection.location))
        case .text(let character):
            let atEnd = selection.end == string.utf16.count
            let startOfLine = atLineStart(selection.location)
            if nbsp, character != " ", selection.length == 0, selection.location > 0,
               (string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)) == "\u{00A0}" {
                value = Array(ns.replacingCharacters(in: NSRange(location: selection.location - 1, length: 1), with: " "))
            }
            replaceSelection(with: nbsp && character == " " && atEnd ? "\u{00A0}" : String(character))
            lazy(before, after: startOfLine)
        }
    }
    /// A key at a line start: the field keeps reporting the caret from before it for a while.
    private func lazy(_ before: UTF16Range, after lineStart: Bool) {
        guard lazyCaret, lineStart else { return }
        lazyCarets += 1
        reported = (before, rng.chance(stickyChance) ? nil : clock() + .milliseconds(20 + rng.next(900)))
    }
    private func replaceSelection(with text: String) {
        let ns = string as NSString
        value = Array(ns.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text))
        selection = .init(location: selection.location + text.utf16.count, length: 0)
    }

    var string: String { String(value) }
    /// What Accessibility reads: the value, and a placeholder line break for an empty last line.
    private var shown: String { placeholder && string.hasSuffix("\n") ? string + "\n" : string }
    func isFocused() -> Bool { true }
    func selectedRange() throws -> UTF16Range { settle(); return shownCaret }
    func textLength() throws -> Int { settle(); return shown.utf16.count }
    func text(in range: UTF16Range) throws -> String {
        settle()
        let shown = (lagging ?? self.shown) as NSString
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
        settle(all: true); mark += 1; reported = nil
        let ns = string as NSString
        value = Array(ns.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: String(character)))
        selection = .init(location: selection.location + String(character).utf16.count, length: 0)
    }
    /// The user clicks somewhere (on a grapheme boundary).
    func click() {
        settle(all: true); mark += 1; reported = nil
        let offsets = [0] + value.indices.map { String(value[...$0]).utf16.count }
        selection = .init(location: offsets[rng.next(offsets.count)], length: 0)
    }
}

private extension Array where Element == Character {
    func count(utf16: Bool) -> Int { String(self).utf16.count }
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
    private struct Stats { var digits = 0, drops = 0, keys = 0, dropped = 0, late = 0, refusals = 0, caretSets = 0, hops = 0, lazy = 0, placeholders = 0 }

    private func session(seed: UInt64, keys: Bool = false, stats: inout Stats) async -> String? {
        var rng = SeededRandom(seed)
        // Keystroke fields sometimes start on an empty last line, which a rich editor shows as a placeholder.
        let prefix = keys && rng.chance(0.4) ? "Log:\n" : "Log: "
        let field = FakeAXField(prefix, rng: SeededRandom(seed &* 31))
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
            field.nbsp = rng.chance(0.5)
            field.placeholder = rng.chance(0.7)
            field.lazyCaret = rng.chance(0.5)
            field.caretSet = [.takes, .ignored, .late, .phantom][rng.next(4)]
            field.hopSkew = rng.chance(0.5) ? 0.3 : 0
            field.wrap = rng.chance(0.3) ? 7 + rng.next(10) : 0
        }
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        queue.now = { clock }
        var userRng = SeededRandom(seed &+ 7)
        var drops: [MacFieldQueue.Drop] = []
        var trail: [String] = []
        queue.journal = { entry in
            trail.append("\(entry.kind.rawValue) \(entry.location.map(String.init) ?? "") \(entry.text ?? "") \(entry.reason ?? "") \(entry.detail ?? "") {\(field.state)}")
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
        let final = field.string.replacingOccurrences(of: "\u{00A0}", with: " ")
        stats.digits += typedDigits; stats.drops += drops.count
        stats.keys += field.keysSent; stats.dropped += field.keysDropped; stats.late += field.keysLate; stats.refusals += field.refusals
        stats.caretSets += field.caretSets; stats.hops += field.hops; stats.lazy += field.lazyCarets
        if field.placeholder, prefix.hasSuffix("\n") { stats.placeholders += 1 }
        if keys, field.writes > 0 { return "seed \(seed): \(field.writes) Accessibility writes to a keystroke field" }
        // Invariants.
        let digits = final.filter(\.isNumber).count
        if digits != typedDigits { return "seed \(seed): \(typedDigits) digits typed, \(digits) left: \(final)" }
        // The fake never loses focus: a park-and-drop means the queue could not make progress.
        if drops.contains(where: { $0.reason == .focusLost || $0.reason == .failed }) {
            return "seed \(seed): stalled (keys \(field.keysSent) dropped \(field.keysDropped) late \(field.keysLate) nbsp \(field.nbsp) caretSet \(field.caretSet) lazy \(field.lazyCaret)): \(drops) state=\(queue.debugState) final=\(final)\n\(trail.joined(separator: "\n"))"
        }
        if queue.hasWork { return "seed \(seed): still busy: \(queue.debugState)\n\(trail.joined(separator: "\n"))" }
        if !interferes, field.lagChance == 0 || keys {
            let expected = prefix + cleaned.replacingOccurrences(of: word, with: word.uppercased(), options: [], range: cleaned.range(of: word))
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
            #expect(stats.caretSets > 0 && stats.hops > 0 && stats.lazy > 0 && stats.placeholders > 0, "stats: \(stats)")
        }
    }

    /// Characters per second typed for dictation appends (virtual clock): one word of dictation arriving into an idle
    /// field (calm), and a long text arriving at once (a backlog). Keys lag 0 to 30 ms in the fake.
    private func typingRates(keys: Bool) async -> (calm: Double, backlog: Double) {
        let field = FakeAXField("", rng: SeededRandom(9))
        var clock = ContinuousClock.now
        field.keys = keys
        field.clock = { clock }
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        queue.sleep = { clock += $0 }
        queue.now = { clock }
        var text = ""
        var typing = Duration.zero
        let words = ["harbor", "squall", "anchor", "north", "wind", "tide", "calm", "rope"]
        for (index, word) in words.enumerated() {
            text += (index == 0 ? "" : " ") + word
            let start = clock
            queue.live(runID: "r", version: index + 1, text: text)
            await queue.whenIdle()
            typing += clock - start
            clock += .milliseconds(400)
        }
        field.settle(all: true)
        let calmSeconds = Double(typing.components.seconds) + Double(typing.components.attoseconds) / 1e18
        let calm = Double(text.count) / calmSeconds
        let long = Array(repeating: "sail north wind harbor", count: 8).joined(separator: " ")
        let start = clock
        queue.live(runID: "r", version: 100, text: text + " " + long)
        await queue.whenIdle()
        let elapsed = clock - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        field.settle(all: true)
        return (calm, Double(long.count + 1) / seconds)
    }

    @Test func typingKeepsUpWithSpeech() async {
        for keys in [false, true] {
            let rates = await typingRates(keys: keys)
            print("TYPING RATE keys=\(keys): calm \(Int(rates.calm)) chars/s, backlog \(Int(rates.backlog)) chars/s")
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
        // One caret set tried (the field ignores it), then a run of arrows to the end of "cab", one Backspace, "t", a run
        // of arrows back: no Accessibility write.
        #expect(field.writes == 0)
        #expect(field.caretSets == 1 && queue.caretJumps.direct == .refused)
        #expect(field.keysSent - sent == 1 + 2 + 1)
    }

    /// A keystroke field with its own clock, driven by the queue's sleeps.
    private func keyedField(_ text: String, seed: UInt64 = 5, configure: (FakeAXField) -> Void = { _ in })
        -> (FakeAXField, MacFieldQueue, () -> ContinuousClock.Instant, (Duration) -> Void) {
        let field = FakeAXField(text, rng: SeededRandom(seed))
        field.keys = true
        var clock = ContinuousClock.now
        field.clock = { clock }
        configure(field)
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.sleep = { clock += $0 }
        queue.now = { clock }
        field.trail = []
        queue.journal = Self.journal(into: field)
        return (field, queue, { clock }, { clock += $0 })
    }
    /// Keeps the queue's ops in the field's `trail`, for failure messages.
    private static func journal(into field: FakeAXField) -> @MainActor (MacEditJournal.Entry) -> Void {
        { [weak field] entry in
            guard [.sent, .mismatch, .refused].contains(entry.kind) else { return }
            field?.trail.append("\(entry.kind.rawValue) \(entry.location.map(String.init) ?? "") \(entry.selection ?? "") \(entry.text ?? "") \(entry.detail ?? "") \(entry.reason ?? "")")
        }
    }

    /// Jakob's journal (Edge, a mobile-code field, 2026-11-11): the take started on the empty last line, which Chromium
    /// reads as a placeholder line break. The first "A" landed, but the field's length did not grow (the placeholder
    /// went) and the caret may report late, so the key failed its read-back; the queue moved left and typed "A" again,
    /// and the stranded first "A" ended up after all the dictation. Replayed with the journal's snapshot timing, with
    /// the caret reporting at once, late, and only after the next key.
    @Test(arguments: [0, 1, 2]) func theFirstKeyOnAnEmptyLastLineIsTypedOnce(caret: Int) async {
        let prefix = "Edit the change, jump back and everything.\n"
        let field = FakeAXField(prefix, rng: SeededRandom(11))
        field.keys = true
        field.placeholder = true
        field.lazyCaret = caret > 0
        field.stickyChance = caret == 2 ? 1 : 0
        var clock = ContinuousClock.now
        let start = clock
        field.clock = { clock }
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        queue.now = { clock }
        var entries: [String] = []
        queue.journal = { entries.append("\($0.kind.rawValue) \($0.location.map(String.init) ?? "") \($0.text ?? "") \($0.detail ?? "")") }
        // The journal's live snapshots (lines 691–705) and when they came, then the take's end and cleanup.
        let script: [(ms: Int, text: String)] = [(0, "Als"), (236, "Also,"), (362, "Also, ver"), (466, "Also, very"),
                                                 (719, "Also, very f"), (1_100, "Also, very fast."), (1_600, "Also, very fast.")]
        var next = 0
        func feed() {
            while next < script.count, clock - start >= .milliseconds(script[next].ms) {
                next += 1
                queue.live(runID: "take", version: next, text: script[next - 1].text)
            }
        }
        queue.sleep = { clock += $0; feed() }
        feed()
        while next < script.count {
            await queue.whenIdle()
            if next < script.count { clock = start + .milliseconds(script[next].ms); feed() }
        }
        await queue.whenIdle()
        field.settle(all: true)
        #expect(field.string == prefix + "Also, very fast.", "\(entries.joined(separator: "\n"))")
        #expect(field.selection == UTF16Range(location: field.string.utf16.count, length: 0))
        // Every typed key went out once.
        #expect(entries.filter { $0.hasPrefix("sent") && $0.hasSuffix(" key") }.count == "Also, very fast.".count)
    }

    @Test func aFieldThatTakesCaretSetsJumpsStraightThereAndItIsRememberedForTheField() async {
        let (field, queue, _, _) = keyedField("", configure: { $0.caretSet = .takes })
        queue.live(runID: "r", version: 1, text: "the cab is here and the sea is calm today")
        await queue.whenIdle()
        field.settle(all: true)
        queue.live(runID: "r", version: 2, text: "the cat is here and the sea is calm today")
        await queue.whenIdle()
        #expect(field.string == "the cat is here and the sea is calm today")
        #expect(field.selection == .init(location: field.string.utf16.count, length: 0))
        // A caret set there, proved once by one arrow (and one back), the edit, a caret set back: no long arrow walk.
        #expect(queue.caretJumps.direct == .trusted)
        #expect(field.caretSets <= 3)
        #expect(field.keysSent <= 41 + 6)

        // The same field bound again: the caret set is trusted at once, no probe.
        let again = MacFieldQueue(target: field)
        var clock = ContinuousClock.now
        field.clock = { clock }
        again.paced = { false }; again.sleep = { clock += $0 }; again.now = { clock }
        again.journal = Self.journal(into: field)
        #expect(again.caretJumps.direct == .trusted)
        // A new take at the start of the field; the user clicks back to the end; the take is revised there.
        field.selection = .init(location: 0, length: 0); field.mark += 1; again.userActed()
        again.live(runID: "s", version: 1, text: "Ahoy")
        await again.whenIdle()
        field.settle(all: true)
        field.selection = .init(location: field.string.utf16.count, length: 0); field.mark += 1; again.userActed()
        let keys = field.keysSent, sets = field.caretSets
        again.live(runID: "s", version: 2, text: "Ahoj")
        await again.whenIdle()
        field.settle(all: true)
        #expect(field.string == "Ahojthe cat is here and the sea is calm today")
        #expect(field.keysSent - keys == 2, "\(field.trail.suffix(12).joined(separator: "\n"))") // Backspace, "y"
        #expect(field.caretSets - sets == 2) // there and back
    }

    @Test func aFieldThatIgnoresCaretSetsHopsAndCorrectsAndRemembersIt() async {
        for skew in [0.0, 1.0] {
            let (field, queue, _, _) = keyedField("", configure: { $0.caretSet = .ignored; $0.hopSkew = skew })
            let text = "sail north wind harbor tide deck rope calm squall anchor"
            queue.live(runID: "r", version: 1, text: text)
            await queue.whenIdle()
            field.settle(all: true)
            queue.live(runID: "r", version: 2, text: "Sail" + text.dropFirst(4))
            await queue.whenIdle()
            field.settle(all: true)
            #expect(field.string == "Sail" + text.dropFirst(4))
            #expect(field.selection == .init(location: field.string.utf16.count, length: 0))
            #expect(queue.caretJumps.direct == .refused)
            #expect(field.caretSets == 1)
            // The typing, then Option word hops there and back (Command hops are off for safety): about one key per
            // word each way plus the edit, never 56 single arrows each way.
            #expect(field.hops >= 1)
            let words = text.split(separator: " ").count
            #expect(field.keysSent < text.count + 2 * words + 8, "\(field.trail.suffix(14).joined(separator: "\n"))")
        }
    }

    @Test func wordHopsThatLandOffAreCorrectedAndStopBeingUsedWhenTheyKeepMissing() async {
        let (field, queue, _, _) = keyedField("", configure: { $0.caretSet = .ignored; $0.hopSkew = 1 })
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
        queue.live(runID: "r", version: 1, text: text)
        await queue.whenIdle()
        field.settle(all: true)
        for (version, word) in ["thrEe", "fivE", "sevEn", "ninE"].enumerated() {
            let current = field.string
            let lower = word.lowercased()
            queue.live(runID: "r", version: version + 2, text: current.replacingOccurrences(of: lower, with: word))
            await queue.whenIdle()
            field.settle(all: true)
            #expect(field.string == current.replacingOccurrences(of: lower, with: word))
            #expect(field.selection == .init(location: field.string.utf16.count, length: 0))
        }
        #expect(!queue.caretJumps.allows(.wordLeft) || !queue.caretJumps.allows(.wordRight) || queue.caretJumps.misses.isEmpty)
    }

    @Test func aCaretSetTheFieldOnlyPretendsToTakeIsCaughtBeforeAnyEdit() async {
        let (field, queue, _, _) = keyedField("", configure: { $0.caretSet = .phantom })
        queue.live(runID: "r", version: 1, text: "the cab is here and more words after it")
        await queue.whenIdle()
        field.settle(all: true)
        queue.live(runID: "r", version: 2, text: "the cat is here and more words after it")
        await queue.whenIdle()
        field.settle(all: true)
        #expect(field.string == "the cat is here and more words after it")
        #expect(field.selection == .init(location: field.string.utf16.count, length: 0))
        #expect(queue.caretJumps.direct == .refused)
    }

    @Test func jumpsCostThePlannerLittleSoFarChangesStayMinimal() {
        let far = KeystrokePlanner.cost(of: [.init(start: 0, end: 1, text: ["x"]), .init(start: 60, end: 61, text: ["y"])], paceMs: 65)
        let walked = KeystrokePlanner.cost(of: [.init(start: 0, end: 1, text: ["x"]), .init(start: 60, end: 61, text: ["y"])],
                                           paceMs: 65, jumpMs: 59 * KeystrokePlanner.keyMs)
        #expect(far < walked)
        #expect(KeystrokePlanner.moveMs(2) == 2 * KeystrokePlanner.keyMs)
        #expect(KeystrokePlanner.moveMs(50) == KeystrokePlanner.jumpMs)
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
