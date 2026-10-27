import Foundation

/// The single writer of the vocabulary file (`vocabulary.json`): one JSON snapshot, rewritten atomically.
///
/// Share exactly one instance per file: the actor serializes access only within an instance, so a second
/// instance (or process) writing the same file can overwrite the other's changes. There is no file locking.
/// The keyboard extension never uses this type; it decodes the file read-only with
/// ``VocabularySnapshot/read(from:)``.
///
/// A file with an unknown schema `version`, or one that cannot be decoded, makes every call throw and is
/// never overwritten.
public actor VocabularyStore {
    public let fileURL: URL
    private var cache: VocabularySnapshot?

    public init(fileURL: URL) { self.fileURL = fileURL }

    // MARK: reading

    /// Reads the file into memory, throwing ``VocabularyStoreError/unsupportedVersion(_:)`` for an unknown schema.
    /// Every other call loads on demand, so calling this is only needed to surface a bad file early.
    public func load() throws { _ = try current() }

    /// The vocabulary as of now. A missing file is an empty snapshot.
    public func snapshot() throws -> VocabularySnapshot { try current() }

    // MARK: manual edits

    /// Adds `text` as a manual entry, or returns the existing entry with that text (case-insensitive) after
    /// refreshing its `lastSeen`, merging in `aliases` and `spellings`, and making it manual.
    ///
    /// A manual add is an explicit decision, so it also **unblocks** a blocked entry of the same text;
    /// only learning sources (``learn(text:kind:source:knownIn:id:now:)``) are barred from blocked texts.
    @discardableResult
    public func add(
        text: String, kind: VocabularyEntry.Kind = .term, aliases: [String] = [], spellings: [String] = [],
        now: Date = Date()
    ) throws -> VocabularyEntry {
        try update(now: now) { snap in
            // An alias is a known mishearing: a learned entry of the same text must not stay behind as a term.
            snap.removeLearned(equalToAliases: aliases, exceptTextKey: text)
            if let i = snap.entries.firstIndex(where: { VocabularyEntry.key(for: $0.text) == VocabularyEntry.key(for: text) }) {
                snap.entries[i].source = .manual
                snap.entries[i].blocked = false
                snap.entries[i].lastSeen = now
                snap.entries[i].aliases = Self.merged(snap.entries[i].aliases, aliases)
                snap.entries[i].spellings = Self.merged(snap.entries[i].spellings, spellings)
                return snap.entries[i]
            }
            let entry = VocabularyEntry(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, source: .manual, lastSeen: now,
                aliases: Self.merged([], aliases), spellings: Self.merged([], spellings))
            snap.entries.append(entry)
            return entry
        }
    }

    /// Records a sighting from a learning source. Creates the entry (score 1) or reinforces it (score + 1,
    /// `lastSeen`), counting a repeated `id` once. Returns the entry, or `nil` when the text is blocked
    /// (nothing is changed then).
    @discardableResult
    public func learn(
        text: String, kind: VocabularyEntry.Kind = .term, source: VocabularyEntry.Source, knownIn: [String] = [],
        id: UUID? = nil, now: Date = Date()
    ) throws -> VocabularyEntry? {
        try update(now: now) { snap in
            if snap.isBlocked(text) { return nil }
            if let i = snap.entries.firstIndex(where: { VocabularyEntry.key(for: $0.text) == VocabularyEntry.key(for: text) }) {
                if let id, !snap.entries[i].remember(id) { return snap.entries[i] }
                snap.entries[i].score += 1
                snap.entries[i].lastSeen = now
                return snap.entries[i]
            }
            var entry = VocabularyEntry(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, source: source, lastSeen: now,
                knownIn: knownIn)
            if let id { entry.remember(id) }
            snap.entries.append(entry)
            return entry
        }
    }

    /// Pins the entry: it is always hinted.
    public func pin(id: UUID) throws { try edit(id) { $0.pinned = true } }

    /// Removes the pin.
    public func unpin(id: UUID) throws { try edit(id) { $0.pinned = false } }

    /// Blocks the entry: never hinted, never relearned. It stays in the list as a tombstone and loses its pin.
    public func block(id: UUID) throws { try edit(id) { $0.blocked = true; $0.pinned = false } }

    /// Lifts a block.
    public func unblock(id: UUID) throws { try edit(id) { $0.blocked = false } }

    /// Forgets dictation (or run) `id` everywhere: see ``VocabularySnapshot/forget(_:)``.
    public func forget(id: UUID) throws { try update { $0.forget(id) } }

    /// Deletes the entry. Unlike ``block(id:)`` this lets a learning source add the text again.
    public func remove(id: UUID) throws {
        try update { snap in
            guard snap.entries.contains(where: { $0.id == id }) else { throw VocabularyStoreError.notFound(id) }
            snap.entries.removeAll { $0.id == id }
        }
    }

    /// Changes the entry's text, throwing ``VocabularyStoreError/duplicate(_:)`` when another entry has it.
    public func rename(id: UUID, to text: String) throws {
        try update { snap in
            guard let i = snap.entries.firstIndex(where: { $0.id == id }) else { throw VocabularyStoreError.notFound(id) }
            let key = VocabularyEntry.key(for: text)
            if snap.entries.contains(where: { $0.id != id && VocabularyEntry.key(for: $0.text) == key }) {
                throw VocabularyStoreError.duplicate(key)
            }
            snap.entries[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: mutation hook

    /// Applies `body` to the snapshot, trims the pending lists to their cap (lowest effective score at `now`
    /// goes first), and writes the result atomically. If `body` or the write throws, nothing changes.
    ///
    /// This is the hook the learner uses for its own bookkeeping.
    @discardableResult
    public func update<T>(
        now: Date = Date(), halfLife: TimeInterval = Decay.defaultHalfLife,
        _ body: (inout VocabularySnapshot) throws -> T
    ) throws -> T {
        var snap = try current()
        let result = try body(&snap)
        snap.trimPending(now: now, halfLife: halfLife)
        try write(snap)
        cache = snap
        return result
    }

    // MARK: private

    private func edit(_ id: UUID, _ change: (inout VocabularyEntry) -> Void) throws {
        try update { snap in
            guard let i = snap.entries.firstIndex(where: { $0.id == id }) else { throw VocabularyStoreError.notFound(id) }
            change(&snap.entries[i])
        }
    }

    private func current() throws -> VocabularySnapshot {
        if let cache { return cache }
        let snap = try VocabularySnapshot.read(from: fileURL)
        cache = snap
        return snap
    }

    private func write(_ snap: VocabularySnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VocabularySnapshot.encode(snap).write(to: fileURL, options: .atomic)
    }

    private static func merged(_ existing: [String], _ new: [String]) -> [String] {
        var out = existing
        for s in new {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !out.contains(where: { VocabularyEntry.key(for: $0) == VocabularyEntry.key(for: trimmed) }) {
                out.append(trimmed)
            }
        }
        return out
    }
}
