import Foundation

/// One piece of a live run's target text, in speaking order. A finished sentence (`final`) holds the raw words,
/// or the cleaned sentence once cleanup landed (`cleaned`); the one non-final segment is the speaking head.
public struct LiveSegment: Codable, Equatable, Sendable {
    /// Counts from 0 within the run; the head carries the id its sentence gets once it is final.
    public var id: Int
    public var text: String
    public var cleaned: Bool
    public var final: Bool
    public init(id: Int, text: String, cleaned: Bool = false, final: Bool) {
        self.id = id; self.text = text; self.cleaned = cleaned; self.final = final
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
    /// Edit batches applied (appends and rewrites).
    public var applies = 0
    /// Batches that changed text already in the field.
    public var rewrites = 0
    public var insertedChars = 0
    public var deletedChars = 0
    public var freezes = 0
    /// The last freeze, by cause (`keystroke`, `cursor`, `selection`, `drift`, `field`).
    public var lastFreeze: String?
    public var drifts = 0
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

/// The app's model of one live run: the finished sentences (raw until their cleanup lands) and the speaking
/// head, as the target the keyboard should show. Every change that alters the target bumps `version`.
///
/// A sentence the segmenter cut short (a forced split at 25 words or 8 s) is not finished: its words stay in the
/// speaking head until the segment that really ends it arrives, and the sentence is cleaned as a whole.
public struct LiveDictationRun: Sendable, Equatable {
    public let runID: String
    public private(set) var version = 0
    public private(set) var complete = false
    private var finals: [LiveSegment] = []
    private var keys: [Int: Int] = [:]
    private var head = ""
    /// Cut-short parts of the sentence being spoken, with the keys of their segments.
    private var open: [String] = []
    private var openKeys: [Int] = []

    public init(runID: String = UUID().uuidString) { self.runID = runID }

    public var snapshot: LiveDictationSnapshot {
        var segments = finals
        let speaking = (open + [head]).filter { !$0.isEmpty }.joined(separator: " ")
        if !speaking.isEmpty { segments.append(.init(id: finals.count, text: speaking, final: false)) }
        return .init(runID: runID, version: version, segments: segments, complete: complete)
    }
    public var isEmpty: Bool { finals.isEmpty && head.isEmpty && open.isEmpty }
    public var finalCount: Int { finals.count }

    /// A segment in speaking order; `key` names it. Its words leave the head. `closes` false: the segmenter cut the
    /// sentence short, so the words wait with the head. Returns the whole sentence once a segment closes it (the text
    /// to clean), else nil.
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
        return sentence
    }

    /// The cleaned sentence replaces its raw words. False when nothing changed (no such sentence, or the same text).
    @discardableResult
    public mutating func setCleaned(key: Int, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let index = keys[key], !text.isEmpty, finals[index].text != text || !finals[index].cleaned else { return false }
        let changed = finals[index].text != text
        finals[index].text = text; finals[index].cleaned = true
        if changed { version += 1 }
        return changed
    }

    /// The run's sentences before the one `key` belongs to, as they stand now, joined like the field shows them.
    public func text(before key: Int) -> String {
        guard let index = keys[key] else { return "" }
        return finals[..<index].map(\.text).joined(separator: " ")
    }

    /// The speaking head (the non-final words); empty when none.
    public mutating func setHead(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !complete, text != head else { return }
        head = text
        version += 1
    }

    /// The take ended. Words still speaking stay as the keyboard showed them; a segment that arrives late
    /// (`addFinal`) still lands in this run, and so does a late cleanup.
    public mutating func finish() {
        guard !complete else { return }
        complete = true
        version += 1
    }
}
