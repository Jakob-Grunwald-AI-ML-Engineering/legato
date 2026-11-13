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
///
/// Element identity, like Chromium: the field can recreate its element (`recreate`, after Enter or a new line) or move
/// focus into a nested element whose text starts at its line (`focusChild`), so the bound element no longer reads as
/// focused until the queue binds the focused one (`refocus`). Another field of the same app can take focus
/// (`focusOther`), and the app can go to the back (`frontmost`).
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
    /// The element the target is bound to and the one the app reports focused; `base`: where the bound element's text
    /// starts in the editor (a nested element), `focusedBase` the focused one's.
    var boundElement = 0, focusedElement = 0
    var base = 0, focusedBase = 0
    var frontmost = true
    /// Another field of the same app has focus, with its own text (the editor's is kept aside).
    private var other: (value: [Character], selection: UTF16Range)?
    var rebinds = 0, recreations = 0
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
        guard isFocused() else { refusals += 1; throw FieldKeyRefusal.notFocused }
        if rng.chance(blipChance) { refusals += 1; throw FieldKeyRefusal.notFocused }
        guard mark == self.mark else { refusals += 1; throw FieldKeyRefusal.userInput }
        guard planned.shifted(base) == shownCaret else { refusals += 1; throw FieldKeyRefusal.selectionMoved }
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
        guard isFocused() else { refusals += 1; throw FieldKeyRefusal.notFocused }
        guard mark == self.mark else { refusals += 1; throw FieldKeyRefusal.userInput }
        guard planned.shifted(base) == shownCaret else { refusals += 1; throw FieldKeyRefusal.selectionMoved }
        let range = range.shifted(base)
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
    func isFocused() -> Bool { frontmost && boundElement == focusedElement }
    func refocus(allowOther: Bool) -> FieldRefocus {
        guard frontmost, boundElement != focusedElement else { return .lost }
        let same = other == nil
        guard same || allowOther else { return .declined }
        if !same, let field = other {
            // The other field becomes the bound one; the editor's text is no longer this target's.
            value = field.value; selection = field.selection; other = nil; inFlight = []; reported = nil
        }
        boundElement = focusedElement; base = focusedBase; rebinds += 1
        return .rebound(sameEditor: same)
    }
    /// Another field of the same app has focus.
    var focusIsOther: Bool { other != nil }
    /// A take starts: the target is bound to the element focused now (`AXTextTarget.captureFocused`).
    func capture() { settle(all: true); boundElement = focusedElement; base = focusedBase }
    /// The page rewrote the editor's DOM: its element is a new object (same text, same caret).
    func recreate() { settle(all: true); focusedElement += 1; recreations += 1 }
    /// Focus moved into the nested element of the caret's line (its text starts at the line start), or back to the root.
    func focusChild() {
        settle(all: true)
        let line = (string as NSString).substring(to: min(selection.location, string.utf16.count)) as NSString
        let start = line.range(of: "\n", options: .backwards).location
        focusedBase = start == NSNotFound ? 0 : start + 1
        focusedElement += 1; recreations += 1
    }
    /// The user clicks into another field of the same app, holding `text` with the caret at its end.
    func focusOther(_ text: String) {
        settle(all: true)
        other = (Array(text), UTF16Range(location: text.utf16.count, length: 0))
        focusedElement += 1; focusedBase = 0; mark += 1
    }
    func selectedRange() throws -> UTF16Range { settle(); return shownCaret.shifted(-base) }
    func textLength() throws -> Int { settle(); return shown.utf16.count - base }
    func text(in range: UTF16Range) throws -> String {
        settle()
        let shown = (lagging ?? self.shown) as NSString
        lagging = nil
        let range = range.shifted(base)
        guard range.location >= base, range.end <= shown.length else { throw TextTargetReadError.unsupported }
        return shown.substring(with: NSRange(location: range.location, length: range.length))
    }
    /// The bound element's whole text in one read (`textLength` and `text(in:)` together).
    func wholeText() throws -> String {
        settle()
        let shown = (lagging ?? self.shown) as NSString
        lagging = nil
        guard base <= shown.length else { throw TextTargetReadError.unsupported }
        return shown.substring(from: base)
    }
    func setSelectedRange(_ range: UTF16Range) throws {
        let range = range.shifted(base)
        guard range.location >= base, range.end <= string.utf16.count else { throw TextTargetReadError.unsupported }
        selection = range
    }
    func replace(_ range: UTF16Range, with text: String) throws {
        let range = range.shifted(base)
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
        // A click outside the nested element focuses the editor's root again.
        if selection.location < focusedBase { focusedBase = 0; focusedElement += 1 }
    }
}

private extension UTF16Range {
    func shifted(_ offset: Int) -> UTF16Range { UTF16Range(location: location + offset, length: length) }
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

/// The fake field's text as Chromium exposes a web editor's (`ChromiumElement`): its value has a line break between every
/// two lines, but its selection and range reads leave out the break between two adjacent non-empty lines. Reads go
/// through `AXFieldReader`, like `AXTextTarget`'s in a Chromium app.
@MainActor private final class SplitView: AXTextElement {
    unowned let field: FakeAXField
    let readable: () -> Bool
    var roots: [SplitView] = []
    init(_ field: FakeAXField, readable: @escaping () -> Bool) { self.field = field; self.readable = readable }

    /// The field's text as this element exposes it: the value, the selection's space without the hidden line breaks, and
    /// per value offset the hidden breaks before it.
    private struct View {
        let value: String
        let ranged: [unichar]
        let hiddenBefore: [Int]
        let hidden: Set<Int>
        let selection: UTF16Range
        init(_ value: String, selection: UTF16Range) {
            let units = Array(value.utf16)
            var hidden = Set<Int>(), before = [0], ranged: [unichar] = []
            for (index, unit) in units.enumerated() {
                let isHidden = unit == 0x0A && index > 0 && index + 1 < units.count && units[index - 1] != 0x0A && units[index + 1] != 0x0A
                if isHidden { hidden.insert(index) } else { ranged.append(unit) }
                before.append(before[index] + (isHidden ? 1 : 0))
            }
            self.value = value; self.ranged = ranged; hiddenBefore = before; self.hidden = hidden; self.selection = selection
        }
        func ranged(_ offset: Int) -> Int { offset - hiddenBefore[max(0, min(offset, hiddenBefore.count - 1))] }
    }
    private var memo: View?
    /// The text and selection as the field shows them now.
    private var view: View? {
        guard readable(), let text = try? field.wholeText(), let selection = try? field.selectedRange() else { return nil }
        if let memo, memo.value == text, memo.selection == selection { return memo }
        memo = View(text, selection: selection)
        return memo
    }
    private static func string(_ units: [unichar]) -> String { String(utf16CodeUnits: units, count: units.count) }

    var axValue: String? { view?.value }
    var axCharacterCount: Int? { view?.value.utf16.count }
    var axSelection: UTF16Range? {
        guard let view else { return nil }
        let start = view.ranged(view.selection.location)
        return UTF16Range(location: start, length: view.ranged(view.selection.end) - start)
    }
    func axString(in range: UTF16Range) -> String? {
        guard let view, range.location >= 0, range.length >= 0, range.end <= view.ranged.count else { return nil }
        return Self.string(Array(view.ranged[range.location..<range.end]))
    }
    var axMarkerText: String? { view.map { Self.string($0.ranged) } }
    func axAfterHiddenBreak(end: Bool) -> Bool? {
        guard let view else { return nil }
        let offset = end ? view.selection.end : view.selection.location
        return view.hidden.contains(offset - 1)
    }
    var axEditableRoots: [any AXTextElement] { roots }
}

/// A keystroke field read like `AXTextTarget` reads a Chromium editor: through `AXFieldReader` over `SplitView`s. The
/// focused element may expose nothing (`nestedBroken`: reads go through its editable root), and the whole editor may
/// stop reading (`unreadable`: the queue hands the take to the panel). Keys, focus and caret sets are the fake field's.
@MainActor private final class ReaderField: TextTarget {
    let field: FakeAXField
    var nestedBroken = false
    var unreadable = false
    /// Reads answered by the editable root.
    var rootReads = 0
    private var reader: AXFieldReader!
    init(_ field: FakeAXField) {
        self.field = field
        rebuild()
    }
    private func rebuild() {
        let root = SplitView(field) { [unowned self] in
            if !unreadable { rootReads += 1 }
            return !unreadable
        }
        let element = SplitView(field) { [unowned self] in !unreadable && !nestedBroken }
        element.roots = [root]
        reader = AXFieldReader(element: element)
    }
    var editsInPlace: Bool { field.editsInPlace }
    var typesKeys: Bool { field.typesKeys }
    var inputMark: Int { field.inputMark }
    var fieldKey: AnyHashable? { field.fieldKey }
    func isFocused() -> Bool { field.isFocused() }
    func refocus(allowOther: Bool) -> FieldRefocus {
        // This editor's own element, unreadable through its root too.
        if unreadable, field.frontmost, field.boundElement != field.focusedElement, !field.focusIsOther { return .unreadable }
        let result = field.refocus(allowOther: allowOther)
        if case .rebound = result { rebuild() }
        return result
    }
    func selectedRange() throws -> UTF16Range { try reader.selectedRange() }
    func text(in range: UTF16Range) throws -> String { try reader.text(in: range) }
    func textLength() throws -> Int { try reader.textLength() }
    func setSelectedRange(_ range: UTF16Range) throws { try field.setSelectedRange(range) }
    func replace(_ range: UTF16Range, with text: String) throws { try field.replace(range, with: text) }
    func press(_ key: FieldKey, mark: Int, selection: UTF16Range) throws { try field.press(key, mark: mark, selection: selection) }
    func setCaret(_ range: UTF16Range, mark: Int, selection: UTF16Range) throws { try field.setCaret(range, mark: mark, selection: selection) }
}

@MainActor @Suite struct MacFieldQueueStressTests {
    private static let words = ["sail", "north", "wind", "harbor", "tide", "deck", "rope", "calm", "squall", "anchor"]

    /// One seeded session: a run grows word by word with revisions, then its cleanup lands; Magic rewrites a word; the
    /// user types digits and clicks in between; reads lag. Invariants: the queue goes idle, never deletes or changes a
    /// digit the user typed, and when the user never acted the field ends exactly as dictated and edited.
    private struct Stats {
        var digits = 0, drops = 0, keys = 0, dropped = 0, late = 0, refusals = 0, caretSets = 0, hops = 0, lazy = 0, placeholders = 0, rebinds = 0
        var rootReads = 0, handovers = 0, typedHandovers = 0
    }
    /// How the field reads: as it is; like a Chromium editor's tight list (`ReaderField`: hidden line breaks, a focused
    /// element that sometimes exposes nothing); or like that, with the whole editor unreadable for a while or for good.
    private enum ReadMode { case direct, split, unreadable }

    private func session(seed: UInt64, keys: Bool = false, read: ReadMode = .direct, stats: inout Stats) async -> String? {
        var rng = SeededRandom(seed)
        var modeRng = SeededRandom(seed &+ 101)
        // Keystroke fields sometimes start on an empty last line, which a rich editor shows as a placeholder.
        var prefix = keys && rng.chance(0.4) ? "Log:\n" : "Log: "
        var tail = ""
        if read != .direct {
            // A tight Markdown list: a new item at the end, the end of an item mid-list, a new item mid-list.
            switch modeRng.next(3) {
            case 0: prefix = "Plan:\n1. sail\n2. "
            case 1: prefix = "Plan:\n1. sail"; tail = "\n2. tide\n3. rope"
            default: prefix = "Plan:\n1. sail\n2. "; tail = "\n3. rope"
            }
        }
        let field = FakeAXField(prefix + tail, rng: SeededRandom(seed &* 31))
        field.selection = UTF16Range(location: prefix.utf16.count, length: 0)
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
        let reader = read == .direct ? nil : ReaderField(field)
        if read == .unreadable { field.dropChance = 0 }
        let queue = MacFieldQueue(target: reader ?? field)
        queue.paced = { true }
        queue.now = { clock }
        // The whole editor stops reading a while after the take starts: briefly (under the panel grace) or for the rest
        // of the dictation. Handed-over runs continue in a simulated panel.
        let unreadFrom = clock + .milliseconds(modeRng.next(800))
        let unreadUntil: ContinuousClock.Instant? = modeRng.chance(0.5) ? unreadFrom + .milliseconds(80 + modeRng.next(400)) : nil
        var dictating = true
        var continuation: PanelContinuation?
        var handedOver: [MacFieldQueue.Handover] = []
        if read == .unreadable {
            queue.onUnreadable = { (handovers: [MacFieldQueue.Handover]) in
                handedOver += handovers
                if let run = handovers.first(where: { $0.runID == "run" }) { continuation = PanelContinuation(text: run.text, typed: run.typed) }
            }
        }
        func updateReading() {
            guard let reader, read == .unreadable else { return }
            let started = clock >= unreadFrom
            let ended = unreadUntil.map { clock >= $0 } ?? false
            reader.unreadable = dictating && started && !ended
        }
        var userRng = SeededRandom(seed &+ 7)
        var guaranteedUserInput = false
        // Element identity churns in half the sessions, interfering or not (it keeps the text): the element is recreated
        // (Enter, a new line, a re-render) or focus moves into the caret line's nested element and back, sometimes before
        // the first word.
        var churnRng = SeededRandom(seed &+ 13)
        let churns = churnRng.chance(0.5)
        // Focus moves into nested elements only while dictating: Magic's result range is checked in the editor's text.
        var nests = true
        func churn(_ chance: Double) {
            guard churns, churnRng.chance(chance) else { return }
            if !nests || churnRng.chance(0.6) { field.recreate() } else { field.focusChild() }
        }
        churn(0.5)
        var drops: [MacFieldQueue.Drop] = []
        var trail: [String] = []
        queue.journal = { entry in
            trail.append("\(entry.kind.rawValue) \(entry.location.map(String.init) ?? "") \(entry.text ?? "") \(entry.reason ?? "") \(entry.detail ?? "") {\(field.state)}")
            if trail.count > 600 { trail.removeFirst() }
        }
        queue.onDrop = { drops.append($0) }
        queue.sleep = { duration in
            clock += duration
            // Keys read back every few milliseconds: the user acts at the same rate per time as between paced writes.
            let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            let scale = keys ? min(1, ms / 40) : 1
            churn(0.02 * scale)
            updateReading()
            // The focused element stops or starts exposing its text (its editable root still reads).
            if let reader, modeRng.chance(0.03 * scale) { reader.nestedBroken.toggle() }
            guard interferes else { return }
            // Faster atomic replacements have fewer sleep opportunities. Every interfering session still exercises
            // a real input, while the randomized keys/clicks continue to vary its later interactions.
            if !guaranteedUserInput {
                guaranteedUserInput = true
                field.type(Character(String(typedDigits % 10))); typedDigits += 1; queue.userActed()
            } else if userRng.chance(0.05 * scale) {
                field.type(Character(String(typedDigits % 10))); typedDigits += 1; queue.userActed()
            } else if userRng.chance(0.02 * scale) {
                field.click(); queue.userActed()
            }
        }
        // Dictation: grows, revises a word now and then, ends with a cleanup.
        var spoken: [String] = []
        var version = 0
        func say(_ text: String) {
            version += 1
            queue.live(runID: "run", version: version, text: text)
            // A run the panel took over shows its later versions there.
            if var panel = continuation { _ = panel.rest(of: text); continuation = panel }        }
        updateReading()
        for _ in 0..<(3 + rng.next(6)) {
            spoken.append(Self.words[rng.next(Self.words.count)])
            if spoken.count > 1, rng.chance(0.3) { spoken[rng.next(spoken.count - 1)] = Self.words[rng.next(Self.words.count)] }
            say(spoken.joined(separator: " "))
            for _ in 0..<rng.next(20) { await Task.yield() }
        }
        let cleaned = spoken.joined(separator: " ").capitalizedFirst + "."
        say(cleaned)
        await queue.whenIdle()
        // The editor reads again (the rest of the session needs its text).
        dictating = false; updateReading()
        if let reader { stats.rootReads += reader.rootReads }
        stats.handovers += handedOver.count
        stats.typedHandovers += handedOver.filter { $0.typed > 0 }.count
        // A run the panel took over was typed only up to the handover: the rest is the panel's, typed at the end.
        // Keys still on their way land (a late key the handover counted as typed).
        if !handedOver.isEmpty { field.settle(all: true) }
        let afterHandover = handedOver.isEmpty ? nil : field.string
        // Magic: the first word of the dictation in capitals, from a read of the field as it is now (like the app's read:
        // the editor bound again if its element changed, then its text as the target shows it).
        nests = false
        var magicResult: MacFieldQueue.EditResult?
        _ = queue.ensureFocused()
        let text = ((try? field.text(in: UTF16Range(location: 0, length: field.textLength()))) ?? "") as NSString
        let word = cleaned.split(separator: " ").first.map(String.init) ?? ""
        let hit = text.range(of: word)
        if hit.location != NSNotFound, !word.isEmpty {
            let before = text.substring(with: NSRange(location: max(0, hit.location - 8), length: min(8, hit.location)))
            magicResult = await queue.edit(.init(range: .init(location: hit.location, length: hit.length), scope: word,
                                                 before: before, target: word.uppercased(), caretAfter: true))
            // Its range in the editor's text (the bound element may be a nested one).
            if case .applied(let range)? = magicResult { magicResult = .applied(range.shifted(field.base)) }
        }
        await queue.whenIdle()
        // Without the user's interference: Magic's edit is taken back and put back through the queue.
        if !interferes, case .applied? = magicResult {
            if !(await queue.undo()) { return "seed \(seed): Magic's edit could not be undone: \(field.string)" }
            if !(await queue.redo()) { return "seed \(seed): Magic's edit could not be redone: \(field.string)" }
        }
        if field.keysInFlight > 0 { return "seed \(seed): idle with \(field.keysInFlight) keys in flight: \(queue.debugState)" }
        let final = field.string.replacingOccurrences(of: "\u{00A0}", with: " ")
        stats.digits += typedDigits; stats.drops += drops.count
        stats.keys += field.keysSent; stats.dropped += field.keysDropped; stats.late += field.keysLate; stats.refusals += field.refusals
        stats.caretSets += field.caretSets; stats.hops += field.hops; stats.lazy += field.lazyCarets; stats.rebinds += field.rebinds
        if field.placeholder, prefix.hasSuffix("\n") { stats.placeholders += 1 }
        if keys, field.writes > 0 { return "seed \(seed): \(field.writes) Accessibility writes to a keystroke field" }
        // Invariants.
        // The list's own numbers are not the user's digits.
        let digits = final.filter(\.isNumber).count - (prefix + tail).filter(\.isNumber).count
        if digits != typedDigits { return "seed \(seed): \(typedDigits) digits typed, \(digits) left: \(final)" }
        // The fake never loses focus to another field: a park-and-drop means the queue could not make progress, and a
        // recreated or nested element of the same editor is always found again.
        if drops.contains(where: { $0.reason == .focusLost || $0.reason == .failed || $0.reason == .cannotPlace && $0.runID != nil }) {
            return "seed \(seed): stalled (keys \(field.keysSent) dropped \(field.keysDropped) late \(field.keysLate) nbsp \(field.nbsp) caretSet \(field.caretSet) lazy \(field.lazyCaret)): \(drops) state=\(queue.debugState) final=\(final)\n\(trail.joined(separator: "\n"))"
        }
        if queue.hasWork { return "seed \(seed): still busy: \(queue.debugState)\n\(trail.joined(separator: "\n"))" }
        if let afterHandover {
            // What the field shows of the take, and the panel's rest typed after it: every word once, the newest last word.
            let shown = afterHandover.replacingOccurrences(of: "\u{00A0}", with: " ")
            guard let continuation else { return "seed \(seed): a handover without the take's run: \(handedOver)" }
            if !interferes {
                guard shown.hasPrefix(prefix), shown.hasSuffix(tail) else {
                    return "seed \(seed): the handover changed the field around the take: \(shown) \(handedOver)"
                }
                let body = String(shown.dropFirst(prefix.count).dropLast(tail.count))
                let combined = (body + continuation.rest).split(whereSeparator: \.isWhitespace)
                let words = cleaned.split(whereSeparator: \.isWhitespace)
                if combined.count != words.count || combined.last?.lowercased() != words.last?.lowercased() {
                    return "seed \(seed): field \(body.debugDescription) + panel \(continuation.rest.debugDescription) != \(cleaned) \(handedOver)\n\(trail.joined(separator: "\n"))"
                }
            }
        } else if !interferes, field.lagChance == 0 || keys {
            // The end of an item mid-list gets a space before the take's words.
            let expected = prefix + PanelTake.separator(before: cleaned, after: prefix.last)
                + cleaned.replacingOccurrences(of: word, with: word.uppercased(), options: [], range: cleaned.range(of: word)) + tail
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
        // The sessions really interfered: the user typed, and some work met text the user changed; elements churned.
        if only == nil { #expect(stats.digits > runs && stats.rebinds > runs / 4, "stats: \(stats)") }
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
            #expect(stats.rebinds > runs / 4, "stats: \(stats)")
        }
    }

    /// The same keystroke sessions in a Chromium editor's tight list (`ReaderField`): the selection's space hides the line
    /// breaks between items, and the focused element sometimes exposes nothing, so reads go through its editable root.
    /// `unreadable`: the whole editor also stops reading, briefly or for the rest of the dictation; a run with words left
    /// then goes on in the panel, never dropped, and the field's words plus the panel's rest are the take's, each once.
    /// Reads cost more here, so the gate plays fewer sessions; `LEGATO_STRESS_RUNS` sets a long local run.
    @Test(arguments: [false, true]) func seededTightListSessionsReadThroughTheEditorAndNeverDrop(unreadable: Bool) async {
        let runs = Int(ProcessInfo.processInfo.environment["LEGATO_STRESS_RUNS"] ?? "") ?? 50
        let only = ProcessInfo.processInfo.environment["LEGATO_STRESS_SEED"].flatMap(UInt64.init)
        var failures: [String] = []
        var stats = Stats()
        for seed in only.map({ [$0] }) ?? (1...UInt64(runs)).map({ $0 }) {
            if let failure = await session(seed: seed, keys: true, read: unreadable ? .unreadable : .split, stats: &stats) { failures.append(failure) }
            if failures.count >= 3 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        if only == nil {
            #expect(stats.digits > runs && stats.rootReads > runs && stats.rebinds > runs / 4, "stats: \(stats)")
            if unreadable { #expect(stats.handovers > runs / 5 && stats.typedHandovers > runs / 10, "stats: \(stats)") }
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
            // Speech is about 15 characters a second: typing is well ahead of it, and at least 30 to 40 when behind.
            #expect(rates.calm >= 25, "calm \(rates.calm)")
            #expect(rates.backlog >= 40, "backlog \(rates.backlog)")
        }
    }

    /// Undo and redo take Legato's own changes back and forth through the queue, in an Accessibility field and in a
    /// keystroke field: a finished take, then a Magic edit; a take still growing is not undoable.
    @Test(arguments: [false, true]) func undoAndRedoGoThroughTheQueue(keys: Bool) async {
        let field = FakeAXField("Log: ", rng: SeededRandom(21))
        var clock = ContinuousClock.now
        field.keys = keys
        field.clock = { clock }
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        queue.sleep = { clock += $0 }
        queue.now = { clock }
        var changes = 0
        queue.onHistoryChange = { changes += 1 }
        #expect(!queue.canUndo && !queue.canRedo)

        queue.live(runID: "a", version: 1, text: "sail north")
        await queue.whenIdle()
        // Still growing: nothing to undo yet.
        #expect(!queue.canUndo)
        queue.live(runID: "a", version: 2, text: "Sail north.", complete: true)
        await queue.whenIdle()
        field.settle(all: true)
        #expect(field.string == "Log: Sail north." && queue.canUndo && !queue.canRedo && changes > 0)

        // Magic upper-cases a word; it is a change of its own.
        let hit = (field.string as NSString).range(of: "north")
        let magic = await queue.edit(.init(range: .init(location: hit.location, length: hit.length), scope: "north", before: "Sail ",
                                           after: ".", target: "NORTH", caretAfter: true))
        #expect(magic == .applied(.init(location: hit.location, length: 5)))
        field.settle(all: true)
        #expect(field.string == "Log: Sail NORTH.")

        #expect(await queue.undo())
        field.settle(all: true)
        #expect(field.string == "Log: Sail north." && queue.canUndo && queue.canRedo, "\(field.string) \(queue.canUndo) \(queue.canRedo)")
        #expect(await queue.undo())
        field.settle(all: true)
        #expect(field.string == "Log: " && !queue.canUndo && queue.canRedo)
        #expect(await queue.undo() == false)
        if keys { #expect(field.writes == 0) }

        #expect(await queue.redo())
        field.settle(all: true)
        #expect(field.string == "Log: Sail north." && queue.canUndo && queue.canRedo, "\(field.string) \(queue.canUndo) \(queue.canRedo)")
        #expect(await queue.redo())
        field.settle(all: true)
        #expect(field.string == "Log: Sail NORTH." && !queue.canRedo)
        #expect(await queue.redo() == false)

        // New dictation after an undo ends the redo.
        #expect(await queue.undo())
        queue.live(runID: "b", version: 1, text: "calm", complete: true)
        await queue.whenIdle()
        field.settle(all: true)
        #expect(!queue.canRedo && field.string.contains("calm"))
    }

    /// An edit that is exactly the inverse of the last one (Magic's own Undo) counts as taking it back.
    @Test func anInverseEditIsAnUndoNotANewChange() async {
        let field = FakeAXField("one two three", rng: SeededRandom(22))
        let queue = MacFieldQueue(target: field)
        queue.paced = { false }
        queue.sleep = { _ in }
        _ = await queue.edit(.init(range: .init(location: 4, length: 3), scope: "two", before: "one ", after: " three", target: "TWO"))
        #expect(queue.canUndo && !queue.canRedo)
        _ = await queue.edit(.init(range: .init(location: 4, length: 3), scope: "TWO", before: "one ", after: " three", target: "two"))
        #expect(!queue.canUndo && queue.canRedo && field.string == "one two three")
        #expect(await queue.redo())
        #expect(field.string == "one TWO three")
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

    /// Plays `script` (milliseconds after the start, a run's text) into `queue` on a virtual clock that the queue's sleeps
    /// advance; `events` run once their time has come (the user's keys, the page rewriting its DOM).
    private func replay(_ queue: MacFieldQueue, field: FakeAXField, run: String = "take", script: [(ms: Int, text: String)],
                        events: [(ms: Int, act: () -> Void)] = []) async {
        var clock = ContinuousClock.now
        let start = clock
        field.clock = { clock }
        queue.now = { clock }
        var next = 0, nextEvent = 0
        func feed() {
            while nextEvent < events.count, clock - start >= .milliseconds(events[nextEvent].ms) {
                events[nextEvent].act(); nextEvent += 1
            }
            while next < script.count, clock - start >= .milliseconds(script[next].ms) {
                next += 1
                queue.live(runID: run, version: next, text: script[next - 1].text)
            }
        }
        queue.sleep = { clock += $0; feed() }
        feed()
        while next < script.count || nextEvent < events.count {
            await queue.whenIdle()
            let due = [next < script.count ? script[next].ms : nil, nextEvent < events.count ? events[nextEvent].ms : nil].compactMap { $0 }.min()
            if let due, clock - start < .milliseconds(due) { clock = start + .milliseconds(due) }
            feed()
        }
        await queue.whenIdle()
        field.settle(all: true)
    }

    /// Jakob's journal (Edge, mobile-code, 2026-11-11, lines 2087–2130): he pressed Enter, typed "- " by hand and dictated
    /// the next list point. The take was bound, but Chromium had replaced the focused element by the time the first words
    /// came (and can again mid-take), so the bound element never read as focused: nothing was planned or sent, and every
    /// version dropped as focusLost. Replayed with the journal's versions and timing, the element recreated right after
    /// binding (or focus moved into the list line's nested element) and again mid-take: the take types at the caret.
    @Test(arguments: [false, true], [false, true]) func aTakeWhoseElementWasRecreatedTypesAtTheCaret(keys: Bool, nested: Bool) async {
        let prefix = "Perfect plan:\n- First point.\n- "
        let field = FakeAXField(prefix, rng: SeededRandom(17))
        field.keys = keys
        field.placeholder = keys
        field.capture()
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        var drops: [MacFieldQueue.Drop] = []
        queue.onDrop = { drops.append($0) }
        var entries: [String] = []
        queue.journal = { entries.append("\($0.kind.rawValue) \($0.location.map(String.init) ?? "") \($0.text ?? "") \($0.detail ?? "") \($0.reason ?? "")") }
        let churn = { nested ? field.focusChild() : field.recreate() }
        let script: [(ms: Int, text: String)] = [
            (1912, "Per"), (2026, "Perf"), (2124, "Perfec"), (2257, "Perfect."), (2372, "Perfect. I"), (2489, "Perfect. I don't"),
            (2607, "Perfect. I don't kn"), (2722, "Perfect. I don't know"), (2972, "Perfect. I don't know that"),
            (3088, "Perfect. I don't know that y"), (3203, "Perfect. I don't know that you"), (3450, "Perfect. I don't know that you had"),
            (3567, "Perfect. I don't know that you had alre"), (3683, "Perfect. I don't know that you had already"),
            (3938, "Perfect. I don't know that you had already cre"), (4176, "Perfect. I don't know that you had already created"),
            (4410, "Perfect. I don't know that you had already created that"),
            (4779, "Perfect. I don't know that you had already created that,"),
            (4888, "Perfect. I don't know that you had already created that, so"),
            (5256, "Perfect. I don't know that you had already created that, so that"),
            (5492, "Perfect. I don't know that you had already created that, so that means"),
            (6211, "Perfect. I don't know that you had already created that, so that means it's,"),
            (6450, "Perfect. I don't know that you had already created that, so that means it's, it's quite easy."),
            (8280, "Perfect. I didn't know that you had already created that, so that means it's quite easy.")]
        await replay(queue, field: field, script: script, events: [(5, churn), (3300, churn), (8300, churn)])
        let text = field.string.replacingOccurrences(of: "\u{00A0}", with: " ")
        #expect(text == prefix + script.last!.text, "\(entries.suffix(30).joined(separator: "\n"))")
        #expect(drops.isEmpty && field.rebinds >= 2, "\(drops) rebinds \(field.rebinds)")
        #expect(field.selection == UTF16Range(location: field.string.utf16.count, length: 0))
        #expect(!entries.contains { $0.hasPrefix("dropped") })
    }

    /// The list Jakob writes: each point a take of its own (a fresh binding), and between takes he presses Enter and types
    /// "- " by hand, which recreates the editor's element (or moves focus into the new line's element). Every take types
    /// at the caret he left, in a keystroke field and an Accessibility field.
    @Test(arguments: [false, true], [false, true]) func enterThenDashThenDictateTypesAtTheCaretEveryTime(keys: Bool, nested: Bool) async {
        let field = FakeAXField("Notes:\n- ", rng: SeededRandom(23))
        field.keys = keys
        field.placeholder = keys
        let points = ["first point", "second point, with a comma", "third point", "fourth and last point"]
        var drops: [MacFieldQueue.Drop] = []
        for (index, point) in points.enumerated() {
            if index > 0 {
                // Enter and "- " by hand; Chromium rewrites the list, so the editor's element changes.
                field.type("\n"); nested ? field.focusChild() : field.recreate()
                field.type("-"); field.type(" ")
                if index % 2 == 0 { field.recreate() }
            }
            // A new take binds the element focused now; the page may still swap it before the first words.
            field.capture()
            if index % 2 == 1 { nested ? field.focusChild() : field.recreate() }
            let queue = MacFieldQueue(target: field)
            queue.paced = { true }
            queue.onDrop = { drops.append($0) }
            let words = point.split(separator: " ").map(String.init)
            let script = words.indices.map { (ms: 400 + 150 * $0, text: words[...$0].joined(separator: " ")) }
                + [(ms: 400 + 150 * words.count + 900, text: point.prefix(1).uppercased() + point.dropFirst() + ".")]
            await replay(queue, field: field, run: "take\(index)", script: script,
                         events: [(ms: 400 + 150 * words.count / 2, act: { field.recreate() })])
        }
        let expected = "Notes:\n" + points.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() + "." }.joined(separator: "\n")
        #expect(field.string.replacingOccurrences(of: "\u{00A0}", with: " ") == expected)
        #expect(drops.isEmpty, "\(drops)")
        #expect(field.selection == UTF16Range(location: field.string.utf16.count, length: 0))
    }

    /// Another app in front for the whole take: the take drops once (History and the clipboard), however many versions
    /// come after, and its text is the take's newest.
    @Test func aTakeWhoseFieldIsGoneDropsOnceNotPerVersion() async {
        let field = FakeAXField("Log: ", rng: SeededRandom(31))
        field.keys = true
        field.capture()
        field.frontmost = false
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        var drops: [MacFieldQueue.Drop] = []
        queue.onDrop = { drops.append($0) }
        var dropped = 0
        queue.journal = { if $0.kind == .dropped { dropped += 1 } }
        let script = (1...19).map { (ms: 120 * $0, text: Array(repeating: "word", count: $0).joined(separator: " ")) }
            + [(ms: 6_000, text: "Words, cleaned.")]
        await replay(queue, field: field, script: script)
        #expect(drops.count == 1 && dropped == 1, "\(drops)")
        #expect(drops.first?.reason == .focusLost && drops.first?.runID == "take")
        #expect(field.string == "Log: " && !queue.hasWork)
    }

    /// Jakob's journal (Edge, mobile-code, 2026-11-12): dictating into a tight numbered list, every take waited as
    /// unreadable and dropped as focusLost. Pinned: the focused element exposes nothing and its editable root hides the
    /// line breaks between the items from its selection; the take reads through the root and types into the item.
    @Test(arguments: [false, true]) func aTightListTakeReadsThroughTheEditableRoot(midList: Bool) async {
        let head = midList ? "Plan:\n1. Call the yard" : "Plan:\n1. Call the yard\n2. "
        let tail = midList ? "\n2. Check the rigging" : ""
        let field = FakeAXField(head + tail, rng: SeededRandom(41))
        field.keys = true
        field.selection = UTF16Range(location: head.utf16.count, length: 0)
        let reader = ReaderField(field)
        reader.nestedBroken = true
        let queue = MacFieldQueue(target: reader)
        queue.paced = { true }
        var drops: [MacFieldQueue.Drop] = [], handovers: [MacFieldQueue.Handover] = []
        queue.onDrop = { drops.append($0) }
        queue.onUnreadable = { handovers += $0 }
        let take = midList ? "about the mast" : "Urgent callback."
        let script = [(ms: 0, text: String(take.prefix(4))), (ms: 300, text: take)]
        await replay(queue, field: field, script: script)
        let typed = midList ? " " + take : take
        #expect(field.string.replacingOccurrences(of: "\u{00A0}", with: " ") == head + typed + tail)
        #expect(drops.isEmpty && handovers.isEmpty && reader.rootReads > 0, "\(drops) \(handovers)")
        #expect(field.selection == UTF16Range(location: (head + typed).utf16.count, length: 0))
    }

    /// Pinned: neither the focused element nor its editable root reads. The take is never dropped: what was typed stays,
    /// and the rest goes on in the panel (`onUnreadable`) after the grace, whole when nothing was typed yet.
    @Test(arguments: [false, true]) func aFieldThatReadsNeitherItselfNorItsRootGoesOnInThePanel(midTake: Bool) async {
        let head = "Plan:\n1. Call the yard\n2. "
        let field = FakeAXField(head, rng: SeededRandom(43))
        field.keys = true
        let reader = ReaderField(field)
        reader.nestedBroken = true
        reader.unreadable = !midTake
        let queue = MacFieldQueue(target: reader)
        queue.paced = { true }
        var drops: [MacFieldQueue.Drop] = [], handovers: [MacFieldQueue.Handover] = []
        queue.onDrop = { drops.append($0) }
        queue.onUnreadable = { handovers += $0 }
        let script = [(ms: 0, text: "Urgent"), (ms: 1_500, text: "Urgent callback"), (ms: 1_900, text: "Urgent callback.")]
        await replay(queue, field: field, script: script, events: midTake ? [(ms: 900, act: { reader.unreadable = true })] : [])
        #expect(drops.isEmpty, "\(drops)")
        #expect(handovers.count == 1 && !queue.hasWork, "\(handovers)")
        guard let handover = handovers.first else { return }
        var panel = PanelContinuation(text: handover.text, typed: handover.typed)
        _ = panel.rest(of: "Urgent callback.")
        if midTake {
            // "Urgent" went in live and stays; the panel types the rest once at the end.
            #expect(field.string == head + "Urgent" && handover.typed == 6)
            #expect(panel.rest == " callback.")
        } else {
            #expect(field.string == head && handover.typed == 0 && handover.text == "Urgent")
            #expect(panel.rest == "Urgent callback.")
        }
    }

    /// Another field of the same app takes focus: a take that typed nothing yet types there, at its caret; a take that
    /// already typed into the editor waits for it, then drops once and leaves the other field alone.
    @Test func anotherFieldTakesATakeOnlyBeforeItTypedAnything() async {
        let field = FakeAXField("Log: ", rng: SeededRandom(37))
        field.keys = true
        field.capture()
        field.focusOther("To: ")
        let queue = MacFieldQueue(target: field)
        queue.paced = { true }
        var drops: [MacFieldQueue.Drop] = []
        queue.onDrop = { drops.append($0) }
        await replay(queue, field: field, script: [(100, "ahoy"), (300, "ahoy there")])
        #expect(field.string == "To: ahoy there" && drops.isEmpty, "\(field.string) \(drops)")

        let editor = FakeAXField("Log: ", rng: SeededRandom(41))
        editor.keys = true
        editor.capture()
        let second = MacFieldQueue(target: editor)
        second.paced = { true }
        var lost: [MacFieldQueue.Drop] = []
        second.onDrop = { lost.append($0) }
        await replay(second, field: editor, script: [(100, "sail"), (300, "sail north"), (600, "sail north wind"), (900, "Sail north wind.")],
                     events: [(450, { editor.focusOther("Search") })])
        #expect(lost.count == 1 && lost.first?.reason == .focusLost && lost.first?.text == "Sail north wind.", "\(lost)")
        #expect(editor.string.hasPrefix("Log: sail"), "\(editor.string)")
    }

    @Test func aTrustedConfirmedCaretJumpDoesNotAddAFixedDelayBeforeTheNextEdit() async {
        let (field, queue, clock, _) = keyedField("", configure: { $0.caretSet = .takes })
        queue.live(runID: "timing", version: 1, text: "the cab is here and the sea is calm today")
        await queue.whenIdle()
        queue.live(runID: "timing", version: 2, text: "the cat is here and the sea is calm today")
        await queue.whenIdle()
        #expect(queue.caretJumps.direct == .trusted)
        var jumpedAt: ContinuousClock.Instant?
        var gaps: [Duration] = []
        queue.journal = { entry in
            guard entry.kind == .sent else { return }
            if entry.detail == "caret" { jumpedAt = clock() }
            else if entry.detail == "key", let jump = jumpedAt {
                gaps.append(clock() - jump); jumpedAt = nil
            }
        }
        queue.live(runID: "timing", version: 3, text: "the cap is here and the sea is calm today")
        await queue.whenIdle()
        #expect(field.string == "the cap is here and the sea is calm today")
        #expect(!gaps.isEmpty)
        #expect(gaps.allSatisfy { $0 == .zero })
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
