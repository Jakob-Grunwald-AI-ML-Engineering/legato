import Foundation

/// One term of the personal vocabulary: a name, place, organisation or piece of jargon the user's speech
/// engines and cleanup step should get right.
public struct VocabularyEntry: Sendable, Equatable, Codable, Identifiable {
    /// What sort of thing the term is.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case person, place, organisation, term
    }

    /// Where the entry came from.
    public enum Source: String, Sendable, Codable, CaseIterable {
        /// Typed in by the user.
        case manual
        /// Learned from final dictation text.
        case history
        /// Learned from cleanup diffs (a repeated raw → target fix).
        case cleanup
        /// Learned from a word the user chose from the suggestion slots.
        case choice
    }

    /// How many dictation or run ids `recentIDs` remembers.
    public static let recentIDsCapacity = 16

    public var id: UUID
    /// The correct surface form, as it should be written.
    public var text: String
    public var kind: Kind
    public var source: Source
    /// Accumulated evidence; read it through ``Decay`` so old terms fade.
    public var score: Double
    public var lastSeen: Date
    /// The last ``recentIDsCapacity`` dictation or run ids that reinforced the entry, oldest first. A repeated id counts once.
    public var recentIDs: [UUID]
    /// The language codes in which the spell checker knows the text as a word, checked at learn time.
    public var knownIn: [String]
    /// Whether the term was learned as the target of a repeated cleanup fix.
    public var correctionTarget: Bool
    /// A pinned term is always hinted.
    public var pinned: Bool
    /// A blocked term is never hinted and never relearned; it stays in the list as a tombstone.
    public var blocked: Bool
    /// Known mishearings of the term. They feed the matcher only and are never sent to an engine or the LLM.
    public var aliases: [String]
    /// Alternative correct surface forms. These may be sent to engines.
    public var spellings: [String]

    public init(
        id: UUID = UUID(), text: String, kind: Kind = .term, source: Source = .manual, score: Double = 1,
        lastSeen: Date, recentIDs: [UUID] = [], knownIn: [String] = [], correctionTarget: Bool = false,
        pinned: Bool = false, blocked: Bool = false, aliases: [String] = [], spellings: [String] = []
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.source = source
        self.score = score
        self.lastSeen = lastSeen
        self.recentIDs = recentIDs
        self.knownIn = knownIn
        self.correctionTarget = correctionTarget
        self.pinned = pinned
        self.blocked = blocked
        self.aliases = aliases
        self.spellings = spellings
    }

    /// The comparison key for a text: trimmed and lowercased, so "claude" and "Claude " name one term.
    public static func key(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Like ``key(for:)``, and also blind to diacritics: "Müller" and "muller" share one folded key. Used to
    /// tell whether an alias duplicates another entry.
    public static func foldedKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whether learning created the entry and nothing else vouches for it: not typed in, not pinned, not blocked.
    var isPlainlyLearned: Bool { source != .manual && !pinned && !blocked }

    /// Records `id` in `recentIDs`, dropping the oldest beyond the capacity. Returns `false` (and changes nothing) when it was already there.
    @discardableResult
    public mutating func remember(_ id: UUID) -> Bool {
        guard !recentIDs.contains(id) else { return false }
        recentIDs.append(id)
        if recentIDs.count > Self.recentIDsCapacity {
            recentIDs.removeFirst(recentIDs.count - Self.recentIDsCapacity)
        }
        return true
    }

    /// The entry's score decayed to `now`.
    public func effectiveScore(now: Date, halfLife: TimeInterval = Decay.defaultHalfLife) -> Double {
        Decay.effectiveScore(score, lastSeen: lastSeen, now: now, halfLife: halfLife)
    }
}
