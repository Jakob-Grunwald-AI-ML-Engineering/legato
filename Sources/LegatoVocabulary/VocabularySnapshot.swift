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
