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
public struct LiveDictationRun: Sendable, Equatable {
    public let runID: String
    public private(set) var version = 0
    public private(set) var complete = false
    private var finals: [LiveSegment] = []
    private var keys: [Int: Int] = [:]
    private var head = ""

    public init(runID: String = UUID().uuidString) { self.runID = runID }

    public var snapshot: LiveDictationSnapshot {
        var segments = finals
        if !head.isEmpty { segments.append(.init(id: finals.count, text: head, final: false)) }
        return .init(runID: runID, version: version, segments: segments, complete: complete)
    }
    public var isEmpty: Bool { finals.isEmpty && head.isEmpty }
    public var finalCount: Int { finals.count }

    /// A finished sentence in speaking order; `key` names it for its cleanup. Its words leave the head.
    public mutating func addFinal(key: Int, text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, keys[key] == nil else { return }
        keys[key] = finals.count
        finals.append(.init(id: finals.count, text: text, final: true))
        head = ""
        version += 1
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

    /// The run's sentences before sentence `key`, as they stand now, joined like the field shows them.
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

    /// The take ended: words still in the head stay as they were shown and count as finished.
    public mutating func finish() {
        guard !complete else { return }
        if !head.isEmpty { finals.append(.init(id: finals.count, text: head, final: true)); head = "" }
        complete = true
        version += 1
    }
}
