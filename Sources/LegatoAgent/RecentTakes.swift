import Foundation

/// One finished dictation take: what was heard, what was written, and when.
public struct RecentTake: Sendable, Equatable, Codable {
    public var raw: String
    public var cleaned: String
    /// True when `cleaned` is the result of a cleanup call (a correction worth showing as raw to cleaned);
    /// false when the raw text was inserted as heard (context only).
    public var wasCleaned: Bool
    public var date: Date
    public init(raw: String, cleaned: String, wasCleaned: Bool, date: Date) {
        self.raw = raw; self.cleaned = cleaned; self.wasCleaned = wasCleaned; self.date = date
    }
}

/// The last few dictation takes, kept across sessions so cleanup can spell names and terms consistently and
/// recognise recurring mis-hearings, and so Soniox starts a take knowing what was just said.
/// Five entries, nothing older than two hours; persisted as JSON when a file URL is given (memory only otherwise).
public final class RecentTakesStore: @unchecked Sendable {
    public static let capacity = 5
    public static let maxAge: TimeInterval = 2 * 3600
    /// Characters of raw plus cleaned text sent to cleanup in total (newest kept).
    public static let cleanupBudget = 4000
    /// Characters of cleaned text sent to Soniox as background text (newest kept).
    public static let backgroundBudget = 1500
    /// Longest raw or cleaned text kept per entry.
    static let entryLimit = 2000

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var takes: [RecentTake]
    private var loaded: Bool

    public init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL; self.now = now
        takes = []; loaded = fileURL == nil
    }

    /// Appends a finished take (older than-capacity and expired entries drop) and saves.
    public func record(raw: String, cleaned: String, wasCleaned: Bool) {
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        load()
        takes.append(RecentTake(raw: String(raw.prefix(Self.entryLimit)), cleaned: String(text.prefix(Self.entryLimit)),
                                wasCleaned: wasCleaned, date: now()))
        prune()
        save()
    }

    /// Live entries, oldest first.
    public func recent() -> [RecentTake] {
        lock.lock(); defer { lock.unlock() }
        load()
        let before = takes.count
        prune()
        if takes.count != before { save() }
        return takes
    }

    /// Cleanup context: raw to cleaned pairs of cleaned takes, oldest first, within `cleanupBudget` (newest kept).
    public func correctionPairs() -> [RecentTake] {
        var budget = Self.cleanupBudget
        var kept: [RecentTake] = []
        for take in recent().reversed() where take.wasCleaned {
            let cost = take.raw.count + take.cleaned.count
            guard cost <= budget else { break }
            budget -= cost
            kept.append(take)
        }
        return kept.reversed()
    }

    /// Soniox background text: the recent written takes, newest last, at most `limit` characters.
    public func backgroundText(limit: Int = RecentTakesStore.backgroundBudget) -> String {
        var parts: [String] = []
        var used = 0
        for take in recent().reversed() {
            let cost = take.cleaned.count + (parts.isEmpty ? 0 : 1)
            if used + cost > limit {
                if parts.isEmpty { parts.append(String(take.cleaned.suffix(limit))) }
                break
            }
            used += cost
            parts.append(take.cleaned)
        }
        return parts.reversed().joined(separator: "\n")
    }

    // MARK: Storage (lock held)

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        takes = (try? decoder.decode([RecentTake].self, from: data)) ?? []
        prune()
    }
    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        takes.removeAll { $0.date < cutoff }
        if takes.count > Self.capacity { takes.removeFirst(takes.count - Self.capacity) }
    }
    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(takes) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
