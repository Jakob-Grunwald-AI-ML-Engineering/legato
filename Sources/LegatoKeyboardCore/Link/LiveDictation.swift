import Foundation

/// One piece of a live run's target text, in speaking order. A finished segment (`final`) holds the raw words,
/// or its cleanup unit's cleaned text once cleanup landed (`cleaned`); the one non-final segment is the speaking head.
public struct LiveSegment: Codable, Equatable, Sendable {
    /// Counts from 0 within the run; the head carries the id its sentence gets once it is final.
    public var id: Int
    public var text: String
    public var cleaned: Bool
    public var final: Bool
    /// Set on the segments of a cleaned unit of several segments: the id of the unit's first segment. That one holds
    /// the unit's cleaned text, the others are empty.
    public var unit: Int?
    /// The segment's raw words, on the segments of a cleaned unit of several segments: the keyboard falls back to them
    /// for a unit it can no longer edit whole (part of it is frozen).
    public var raw: String?
    public init(id: Int, text: String, cleaned: Bool = false, final: Bool, unit: Int? = nil, raw: String? = nil) {
        self.id = id; self.text = text; self.cleaned = cleaned; self.final = final; self.unit = unit; self.raw = raw
    }
}

/// app -> keyboard (`link.dictation.live`): where a live run's text should stand now. The whole target is
/// republished on every change (`version` counts up within `runID`); the keyboard diffs it against the field it
/// typed and owns all edits, so only the words that differ are touched.
public struct LiveDictationSnapshot: Codable, Equatable, Sendable {
    public var runID: String
    public var version: Int
    public var segments: [LiveSegment]
    /// The take ended: every word is final. Cleanup may still land later (a higher `version`).
    public var complete: Bool
    public init(runID: String, version: Int, segments: [LiveSegment], complete: Bool = false) {
        self.runID = runID; self.version = version; self.segments = segments; self.complete = complete
    }
}

/// What the keyboard did so far in a run: counts and characters only, never text.
public struct LiveDictationStats: Codable, Equatable, Sendable {
    /// Edit ops sent to the field (one at a time through the edit queue).
    public var applies = 0
    /// Edits that changed text already in the field (each a diff of one or more ops).
    public var rewrites = 0
    /// Times the queue waited for the field to confirm an op, and waits that ran out (each froze the run).
    public var waits = 0
    public var confirmTimeouts = 0
    /// Snapshots dropped undiffed because a newer one arrived while the queue was busy.
    public var coalesced = 0
    public var insertedChars = 0
    public var deletedChars = 0
    public var freezes = 0
    /// The last freeze, by cause (`keystroke`, `cursor`, `selection`, `drift`, `field`).
    public var lastFreeze: String?
    public var drifts = 0
    /// How the last drift looked (lengths and character kinds, no text).
    public var lastDrift: String?
    /// What the last region was anchored to when it began typing (lengths and kinds, no text).
    public var lastStart: String?
    public init() {}
}

/// keyboard -> app (`link.dictation.live.ack`): the run's `version` the field fully shows (or `nil` while only
/// stats changed), for latency and diagnostics. The app never waits for it.
public struct LiveDictationAck: Codable, Equatable, Sendable {
    public var runID: String
    public var version: Int?
    /// The applied version was the complete take.
    public var complete: Bool
    public var stats: LiveDictationStats
    public init(runID: String, version: Int?, complete: Bool = false, stats: LiveDictationStats) {
        self.runID = runID; self.version = version; self.complete = complete; self.stats = stats
    }
}

public struct LiveDictationLink: Sendable {
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }
    public func publish(_ value: LiveDictationSnapshot) { store.write(value, forKey: LinkChannel.Key.dictationLive) }
    public func clear() { store.remove(forKey: LinkChannel.Key.dictationLive) }
    public func read() -> LiveDictationSnapshot? { store.read(LiveDictationSnapshot.self, forKey: LinkChannel.Key.dictationLive) }
    public func acknowledge(_ ack: LiveDictationAck) { store.write(ack, forKey: LinkChannel.Key.dictationLiveAck) }
    public func acknowledged() -> LiveDictationAck? { store.read(LiveDictationAck.self, forKey: LinkChannel.Key.dictationLiveAck) }
}

/// The app's model of one live run: the finished segments and the speaking head, as the target the keyboard
/// should show. Every change that alters the target bumps `version`.
///
/// Cleanup works on *units*, not on single segments: the endpointer cuts at every speaking pause ("Um.", "so, uh,
/// the plan"), so consecutive segments are grouped until the unit ends a sentence (`.`, `?`, `!`, `…`) with at least
/// `minUnitWords` words, ends in a line break, or reaches `maxUnitWords`. `flush()` closes the open unit at the
/// take's end. A closed unit is cleaned whole; an empty cleaned text drops its words.
///
/// Cleaned units are held back while the take runs: the target is the raw finals and the head, so the field only
/// changes at its live end. `finish()` puts every cleaned unit in at once (one diff); a cleanup that lands after the
/// end goes in when it lands.
///
/// A sentence the segmenter cut short (a forced split at 25 words or 8 s) is not finished: its words stay in the
/// speaking head until the segment that really ends it arrives.
public struct LiveDictationRun: Sendable, Equatable {
    /// A unit ends a sentence only with this many words; shorter ones ("Um.", "Yeah.", "I think.") join the next.
    public static let minUnitWords = 6
    /// A unit closes at this many words even without a sentence end.
    public static let maxUnitWords = 40

    public let runID: String
    public private(set) var version = 0
    public private(set) var complete = false
    private var finals: [LiveSegment] = []
    /// Cleanup units as ranges of `finals`; the last is open while `openUnit`.
    private var units: [Range<Int>] = []
    private var openUnit = false
    /// Cleaned text by unit index, shown from `finish()` on.
    private var cleaned: [Int: String] = [:]
    /// The whole take cleaned in one call (`setWhole`): it replaces the finals before `end` and their units.
    private var whole: Whole?
    private struct Whole: Sendable, Equatable { var end: Int; var text: String }
    private var keys: [Int: Int] = [:]
    private var head = ""
    /// Cut-short parts of the sentence being spoken, with the keys of their segments.
    private var open: [String] = []
    private var openKeys: [Int] = []

    public init(runID: String = UUID().uuidString) { self.runID = runID }

    public var snapshot: LiveDictationSnapshot {
        var segments = finals
        if complete {
            if let whole {
                for i in 0..<whole.end {
                    segments[i].raw = finals[i].text
                    segments[i].text = i == 0 ? whole.text : ""
                    segments[i].cleaned = true; segments[i].unit = 0
                }
                if whole.end == 1 { segments[0].raw = nil; segments[0].unit = nil }
            }
            for (index, text) in cleaned where units[index].lowerBound >= (whole?.end ?? 0) {
                let range = units[index]
                if range.count == 1 {
                    segments[range.lowerBound].text = text; segments[range.lowerBound].cleaned = true
                    continue
                }
                for i in range {
                    segments[i].raw = finals[i].text
                    segments[i].text = i == range.lowerBound ? text : ""
                    segments[i].cleaned = true; segments[i].unit = range.lowerBound
                }
            }
        }
        let speaking = (open + [head]).filter { !$0.isEmpty }.joined(separator: " ")
        if !speaking.isEmpty { segments.append(.init(id: finals.count, text: speaking, final: false)) }
        return .init(runID: runID, version: version, segments: segments, complete: complete)
    }
    public var isEmpty: Bool { finals.isEmpty && head.isEmpty && open.isEmpty }
    public var finalCount: Int { finals.count }
    /// Words are still being spoken (a head or cut-short parts): their final segment is still to come.
    public var isSpeaking: Bool { !head.isEmpty || !open.isEmpty }
    public var unitCount: Int { units.count }

    /// A segment in speaking order; `key` names it. Its words leave the head. `closes` false: the segmenter cut the
    /// sentence short, so the words wait with the head. Returns the unit's text when this segment closes its unit (the
    /// text to clean, under this `key`), else nil. After `finish()` (a late segment) every segment closes its unit.
    @discardableResult
    public mutating func addFinal(key: Int, text: String, closes: Bool = true) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, keys[key] == nil, !openKeys.contains(key) else { return nil }
        head = ""
        guard closes else {
            open.append(text); openKeys.append(key)
            version += 1
            return nil
        }
        let sentence = (open + [text]).joined(separator: " ")
        for k in openKeys + [key] { keys[k] = finals.count }
        finals.append(.init(id: finals.count, text: sentence, final: true))
        open = []; openKeys = []
        version += 1
        if openUnit, let last = units.last { units[units.count - 1] = last.lowerBound..<finals.count }
        else { units.append((finals.count - 1)..<finals.count); openUnit = true }
        let unit = rawText(units.count - 1)
        guard complete || Self.endsUnit(unit) else { return nil }
        openUnit = false
        return unit
    }

    /// Closes the open unit (the take ends): its text and the key of its last segment, the cleanup's key. Nil when
    /// no unit is open. The target does not change.
    public mutating func flush() -> (key: Int, text: String)? {
        guard openUnit, let range = units.last else { return nil }
        openUnit = false
        guard let key = keys.filter({ $0.value == range.upperBound - 1 }).map(\.key).max() else { return nil }
        return (key, rawText(units.count - 1))
    }

    /// Whether a unit's raw text is a whole unit: a sentence end with enough words, a line break, or the word cap.
    static func endsUnit(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words >= maxUnitWords { return true }
        if let last = text.trimmingCharacters(in: .whitespaces).last, last.isNewline { return true }
        return words >= minUnitWords && !text.trimmingCharacters(in: .whitespaces).isEmpty && SentenceStart.endsSentence(text)
    }

    private func unitIndex(ofKey key: Int) -> Int? {
        guard let index = keys[key] else { return nil }
        return units.firstIndex { $0.contains(index) }
    }
    private func rawText(_ unit: Int) -> String { finals[units[unit]].map(\.text).joined(separator: " ") }
    private func shownText(_ unit: Int) -> String { cleaned[unit] ?? rawText(unit) }

    /// The raw words of every final so far, and how many finals and words that is: what `setWhole` replaces.
    public var wholeRaw: (finals: Int, words: Int, text: String) {
        let text = finals.map(\.text).joined(separator: " ")
        return (finals.count, text.split(whereSeparator: \.isWhitespace).count, text)
    }

    /// The whole take, cleaned in one call at its end: replaces the first `finals` finals (all units within them)
    /// once the take is complete. An empty text drops them. False for no finals or a count that no longer fits.
    @discardableResult
    public mutating func setWhole(_ text: String, finals count: Int) -> Bool {
        guard count > 0, count <= finals.count, units.allSatisfy({ $0.upperBound <= count || $0.lowerBound >= count }) else { return false }
        whole = Whole(end: count, text: text.trimmingCharacters(in: .whitespaces))
        if complete { version += 1 }
        return true
    }

    /// How many segments the unit `key` belongs to holds (0: no such unit).
    public func unitSegments(key: Int) -> Int { unitIndex(ofKey: key).map { units[$0].count } ?? 0 }

    /// The cleaned text of the unit `key` belongs to (empty: the unit's words are dropped); it shows from `finish()`
    /// on (at once after it). True when the target changed now: false while the take runs, and for no such unit or
    /// the same text.
    @discardableResult
    public mutating func setCleaned(key: Int, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let unit = unitIndex(ofKey: key) else { return false }
        let shown = shownText(unit)
        cleaned[unit] = text
        // A unit the whole take's cleanup covers is shown by that.
        guard complete, shown != text, units[unit].lowerBound >= (whole?.end ?? 0) else { return false }
        version += 1
        return true
    }

    /// The run's units before the one `key` belongs to, cleaned where cleanup landed, joined like the field
    /// will show them.
    public func text(before key: Int) -> String {
        guard let unit = unitIndex(ofKey: key) else { return "" }
        return (0..<unit).map(shownText).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The speaking head (the non-final words); empty when none.
    public mutating func setHead(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !complete, text != head else { return }
        head = text
        version += 1
    }

    /// The take ended: the cleaned units go into the target. Words still speaking stay as the keyboard showed
    /// them; a segment that arrives late (`addFinal`) still lands in this run, and so does a late cleanup.
    public mutating func finish() {
        guard !complete else { return }
        complete = true
        version += 1
    }
}
