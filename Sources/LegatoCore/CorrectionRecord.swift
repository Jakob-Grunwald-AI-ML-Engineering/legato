import Foundation

/// Observations, not automatic dictionary rules. A host change can also be autocorrect or another editor.
public struct CorrectionRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable { case keyboard, observedHost }
    public var id = UUID()
    public var date: Date
    public var dictationID: String
    public var platform: String
    public var localeIdentifier: String
    public var rawText: String
    public var insertedText: String
    public var beforeText: String
    public var afterText: String
    public var removed: String
    public var replacement: String
    public var contextBefore: String
    public var contextAfter: String
    /// A blank composer closed observation immediately after this edit.
    public var endedAtBoundary: Bool? = nil
    /// False when the user disabled learning before this observation was saved.
    public var eligibleForLearning: Bool? = nil
    public var origin: Origin
}

/// Immutable files avoid a read/delete in the app rewriting an extension's concurrent append.
public actor CorrectionStore {
    public static let directoryName = "Corrections"
    public nonisolated let directory: URL
    public init(root: URL) { directory = root.appendingPathComponent(Self.directoryName, isDirectory: true) }
    public func append(_ observation: CorrectionRecord) throws {
        var record = observation
        if try !personalizationEnabled() { record.eligibleForLearning = false }
        try PrivateFiles.createDirectory(directory)
        try PrivateFiles.write(JSONEncoder().encode(record), to: directory.appendingPathComponent(record.id.uuidString + ".json"))
    }
    public func recent(limit: Int = 200) throws -> [CorrectionRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CorrectionRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CorrectionRecord.self, from: data)
            }.sorted { $0.date > $1.date }.prefix(max(0, limit)).map { $0 }
    }
    public func delete(id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Watches one delivered scope, bounded by unchanged surrounding text. Selection/cursor movement alone has no effect.
/// Proxy windows that shift or edits crossing the scope's boundaries retire it rather than inventing a correction.
public struct CorrectionTracker: Sendable {
    public let dictationID: String
    public let rawText: String
    public let insertedText: String
    public let platform: String
    public let localeIdentifier: String
    private let prefix: String
    private let suffix: String
    private var settled: String
    private var candidate: String
    private var endedAtBoundary = false
    private var changedAt: Date?
    private var origin = CorrectionRecord.Origin.observedHost
    private let expires: Date
    public private(set) var active = true
    public init?(dictationID: String, rawText: String, insertedText: String, snapshot: String,
                 platform: String, localeIdentifier: String, now: Date = Date()) {
        guard !insertedText.isEmpty, snapshot.count <= 60_000 else { return nil }
        // The field may capitalize the initial grapheme. Preserve that actual delivered baseline.
        let capitalized = String(insertedText.prefix(1)).uppercased() + insertedText.dropFirst()
        var matches: [Range<String.Index>] = []
        for target in Set([insertedText, capitalized]) {
            var search = snapshot.startIndex..<snapshot.endIndex
            while let range = snapshot.range(of: target, range: search) {
                matches.append(range)
                guard matches.count <= 1 else { return nil }
                search = range.upperBound..<snapshot.endIndex
            }
        }
        guard let range = matches.first else { return nil }
        let delivered = String(snapshot[range])
        self.dictationID = dictationID; self.rawText = rawText; self.insertedText = delivered
        self.platform = platform; self.localeIdentifier = localeIdentifier
        prefix = String(snapshot[..<range.lowerBound]); suffix = String(snapshot[range.upperBound...])
        settled = delivered; candidate = delivered; expires = now.addingTimeInterval(600)
    }
    fileprivate func containsCursor(in snapshot: String, at cursor: Int, now: Date) -> Bool {
        active && now <= expires && snapshot.hasPrefix(prefix) && snapshot.hasSuffix(suffix)
            && cursor >= prefix.count && cursor <= snapshot.count - suffix.count
    }

    public mutating func observe(_ snapshot: String, origin: CorrectionRecord.Origin, now: Date = Date()) {
        guard active, now <= expires, snapshot.count <= 60_000 else { active = false; return }
        if snapshot.allSatisfy(\.isWhitespace) {
            endedAtBoundary = true
            active = false
            return
        }
        guard snapshot.hasPrefix(prefix), snapshot.hasSuffix(suffix), snapshot.count >= prefix.count + suffix.count else {
            active = false; return
        }
        let value = String(snapshot.dropFirst(prefix.count).dropLast(suffix.count))
        if value != candidate { candidate = value; changedAt = now; self.origin = origin }
    }
    /// A one-second pause groups backspacing and replacement typing into one observation.
    public mutating func settle(now: Date = Date()) -> CorrectionRecord? {
        guard active || endedAtBoundary, now <= expires, let changedAt, candidate != settled,
              endedAtBoundary || now.timeIntervalSince(changedAt) >= 1 else { return nil }
        let old = Array(settled), new = Array(candidate)
        var head = 0, tail = 0
        while head < min(old.count, new.count), old[head] == new[head] { head += 1 }
        while tail < min(old.count, new.count) - head, old[old.count - tail - 1] == new[new.count - tail - 1] { tail += 1 }
        // Keep whole changed tokens in the evidence/UI: "John" → "Joan", not just "h" → "a".
        while head > 0, !old[head - 1].isWhitespace { head -= 1 }
        while tail > 0, !old[old.count - tail].isWhitespace { tail -= 1 }
        let record = CorrectionRecord(date: now, dictationID: dictationID, platform: platform,
            localeIdentifier: localeIdentifier, rawText: rawText, insertedText: insertedText,
            beforeText: settled, afterText: candidate, removed: String(old[head..<(old.count - tail)]),
            replacement: String(new[head..<(new.count - tail)]),
            contextBefore: String((prefix + String(old.prefix(head))).suffix(80)),
            contextAfter: String((String(old.suffix(tail)) + suffix).prefix(80)), endedAtBoundary: endedAtBoundary ? true : nil, origin: origin)
        settled = candidate; self.changedAt = nil
        return record
    }
}

/// Platform adapters feed only settled, readable snapshots and discard observations around Legato writes.
@MainActor public final class CorrectionCapture {
    public let store: CorrectionStore
    private var trackers: [CorrectionTracker] = []
    public var isObserving: Bool { !trackers.isEmpty }
    private var pending: [String: (raw: String, text: String)] = [:]
    private var ownWriteAt = Date.distantPast
    private var keyAt = Date.distantPast
    public enum UnmatchedSourcePolicy { case retain, discard }
    public func watch(dictationID: String, raw: String, inserted: String) {
        pending[dictationID] = (raw, inserted)
    }
    public func ownWrite(now: Date = Date()) { trackers = []; ownWriteAt = now }
    public func anchoredTakeID(in snapshot: String, at cursor: Int) -> String? {
        let now = Date()
        let matches = trackers.filter { $0.containsCursor(in: snapshot, at: cursor, now: now) }
        return matches.count == 1 ? matches.first?.dictationID : nil
    }

    public func userWrite(now: Date = Date()) { keyAt = now }
    public func canObserve(now: Date = Date()) -> Bool { now.timeIntervalSince(ownWriteAt) >= 0.15 }
    @discardableResult public func armPending(snapshot: String, platform: String, locale: String, isIdle: Bool,
                                             unmatched: UnmatchedSourcePolicy) -> Int {
        guard isIdle else { return 0 }
        var armed = 0
        for (id, source) in pending {
            if arm(dictationID: id, raw: source.raw, inserted: source.text, snapshot: snapshot,
                   platform: platform, locale: locale, isIdle: true) {
                pending.removeValue(forKey: id); armed += 1
            } else if unmatched == .discard { pending.removeValue(forKey: id) }
        }
        return armed
    }
    public func observeSettled(_ snapshot: String, now: Date = Date()) {
        guard canObserve(now: now) else { return }
        observe(snapshot, origin: now.timeIntervalSince(keyAt) < 2 ? .keyboard : .observedHost, now: now)
    }
    public private(set) var lastError: String?
    public init(store: CorrectionStore) { self.store = store }
    public func reset() { trackers = []; pending = [:]; ownWriteAt = .distantPast; keyAt = .distantPast }
    @discardableResult public func arm(dictationID: String, raw: String, inserted: String, snapshot: String, platform: String, locale: String, isIdle: Bool) -> Bool {
        guard isIdle else { return false }
        trackers.removeAll { $0.dictationID == dictationID || !$0.active }
        if let tracker = CorrectionTracker(dictationID: dictationID, rawText: raw, insertedText: inserted,
                                            snapshot: snapshot, platform: platform, localeIdentifier: locale) {
            trackers.append(tracker)
            trackers = Array(trackers.suffix(20))
            return true
        }
        return false
    }
    public func observe(_ snapshot: String, origin: CorrectionRecord.Origin, now: Date = Date()) {
        var records: [CorrectionRecord] = []
        for i in trackers.indices {
            trackers[i].observe(snapshot, origin: origin, now: now)
            if let record = trackers[i].settle(now: now) { records.append(record) }
        }
        trackers.removeAll { !$0.active }
        guard !records.isEmpty else { return }
        Task {
            do { for record in records { try await store.append(record) }; lastError = nil }
            catch { lastError = "Could not save corrections: \(error.localizedDescription)" }
        }
    }
}
