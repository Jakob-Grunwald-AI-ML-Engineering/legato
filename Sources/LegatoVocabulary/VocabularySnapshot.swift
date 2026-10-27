import Foundation

/// The whole vocabulary file: entries plus the candidates still waiting for enough evidence.
///
/// The app's ``VocabularyStore`` writes it; the keyboard extension decodes it read-only with ``read(from:)``.
/// Dates are stored as integer milliseconds since 1970, like history.
public struct VocabularySnapshot: Sendable, Equatable, Codable {
    /// The schema version this build reads and writes.
    public static let currentVersion = 1
    /// How many pending terms, and how many pending fixes, are kept.
    public static let pendingCap = 500

    public var version: Int
    public var entries: [VocabularyEntry]
    public var pendingTerms: [PendingTerm]
    public var pendingFixes: [PendingFix]

    public init(
        entries: [VocabularyEntry] = [], pendingTerms: [PendingTerm] = [], pendingFixes: [PendingFix] = []
    ) {
        self.version = Self.currentVersion
        self.entries = entries
        self.pendingTerms = pendingTerms
        self.pendingFixes = pendingFixes
    }

    private enum CodingKeys: String, CodingKey { case version, entries, pendingTerms, pendingFixes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        entries = try c.decodeIfPresent([VocabularyEntry].self, forKey: .entries) ?? []
        pendingTerms = try c.decodeIfPresent([PendingTerm].self, forKey: .pendingTerms) ?? []
        pendingFixes = try c.decodeIfPresent([PendingFix].self, forKey: .pendingFixes) ?? []
    }

    /// The entry with `id`, if any.
    public func entry(id: UUID) -> VocabularyEntry? { entries.first { $0.id == id } }

    /// The entry whose text equals `text` ignoring case and surrounding whitespace, if any.
    public func entry(forText text: String) -> VocabularyEntry? {
        let key = VocabularyEntry.key(for: text)
        return entries.first { VocabularyEntry.key(for: $0.text) == key }
    }

    /// Whether `text` belongs to a blocked entry. Learning sources must check this before adding or reinforcing.
    public func isBlocked(_ text: String) -> Bool { entry(forText: text)?.blocked == true }

    /// Drops what an alias makes redundant: the learned entries (neither manual, pinned nor blocked) and the pending
    /// terms whose text equals one of `aliases` ignoring case and diacritics. A mishearing kept as an entry of its
    /// own would be hinted to the engines and the cleanup model as a correct spelling. The entry whose text
    /// compares equal to `exceptTextKey` (the term that owns the alias) is never dropped.
    public mutating func removeLearned(equalToAliases aliases: [String], exceptTextKey: String? = nil) {
        let keys = Set(aliases.map(VocabularyEntry.foldedKey(for:)).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return }
        let owner = exceptTextKey.map(VocabularyEntry.foldedKey(for:))
        entries.removeAll { entry in
            let key = VocabularyEntry.foldedKey(for: entry.text)
            return entry.isPlainlyLearned && keys.contains(key) && key != owner
        }
        pendingTerms.removeAll { keys.contains(VocabularyEntry.foldedKey(for: $0.text)) }
    }

    /// Takes dictation (or run) `id` back out of everything it taught, for a dictation the user deleted.
    ///
    /// - A pending term or fix loses the id and one point of score; with no ids left it is dropped.
    /// - An entry loses the id from `recentIDs` and one point of score. A learned entry (neither manual,
    ///   pinned nor blocked) whose only sighting was `id` is removed.
    ///
    /// The limit: an entry remembers only its last ``VocabularyEntry/recentIDsCapacity`` ids, and a choice-learned
    /// entry remembers none, so a sighting that fell out of the ring cannot be found again. An entry that
    /// several dictations support stays when one of them goes; the others still evidence it.
    public mutating func forget(_ id: UUID) {
        pendingTerms = pendingTerms.compactMap { term in
            guard term.ids.contains(id) else { return term }
            var term = term
            term.ids.removeAll { $0 == id }
            term.score = max(0, term.score - 1)
            return term.ids.isEmpty ? nil : term
        }
        pendingFixes = pendingFixes.compactMap { fix in
            guard fix.ids.contains(id) else { return fix }
            var fix = fix
            fix.ids.removeAll { $0 == id }
            fix.score = max(0, fix.score - 1)
            return fix.ids.isEmpty ? nil : fix
        }
        entries = entries.compactMap { entry in
            guard entry.recentIDs.contains(id) else { return entry }
            if entry.recentIDs == [id], entry.isPlainlyLearned { return nil }
            var entry = entry
            entry.recentIDs.removeAll { $0 == id }
            entry.score = max(0, entry.score - 1)
            return entry
        }
    }

    /// Drops the lowest-effective-score pending terms and fixes beyond ``pendingCap``; ties evict the older `lastSeen` first.
    public mutating func trimPending(now: Date, halfLife: TimeInterval = Decay.defaultHalfLife) {
        if pendingTerms.count > Self.pendingCap {
            pendingTerms = Self.keepingBest(pendingTerms) {
                ($0.effectiveScore(now: now, halfLife: halfLife), $0.lastSeen)
            }
        }
        if pendingFixes.count > Self.pendingCap {
            pendingFixes = Self.keepingBest(pendingFixes) {
                ($0.effectiveScore(now: now, halfLife: halfLife), $0.lastSeen)
            }
        }
    }

    private static func keepingBest<T>(_ items: [T], rank: (T) -> (Double, Date)) -> [T] {
        let ranked = items.enumerated().map { (offset: $0.offset, rank: rank($0.element)) }
        let keep = ranked.sorted { a, b in
            a.rank.0 != b.rank.0 ? a.rank.0 > b.rank.0 : a.rank.1 > b.rank.1
        }.prefix(pendingCap)
        return keep.map(\.offset).sorted().map { items[$0] }
    }

    /// Reads and checks the file at `url`. A missing file is an empty snapshot; an unknown version throws
    /// ``VocabularyStoreError/unsupportedVersion(_:)``.
    public static func read(from url: URL) throws -> VocabularySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return VocabularySnapshot() }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> VocabularySnapshot {
        struct Probe: Decodable { var version: Int }
        let version = try JSONDecoder().decode(Probe.self, from: data).version
        guard version == currentVersion else { throw VocabularyStoreError.unsupportedVersion(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(VocabularySnapshot.self, from: data)
    }

    static func encode(_ snapshot: VocabularySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        // Whole milliseconds: the default strategy writes a Double that can pick up float noise.
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(snapshot)
    }
}
