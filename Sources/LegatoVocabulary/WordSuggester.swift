import Foundation

/// The words for the keyboard's three slots while typing: completions of the word being typed and predictions
/// of the next one.
public enum WordSuggester {
    /// How many suggestions the keyboard has slots for.
    public static let limit = 3

    /// Completions of `prefix`, best first, at most `limit`.
    ///
    /// In order: single-word vocabulary entries that start with the prefix (pinned first, then by decayed score;
    /// blocked entries and entries that are another entry's alias are skipped, as in ``HintSelector``), then the
    /// word-pair hits for that prefix after `previous`, then the dictionary's completions. The dictionary is
    /// asked only when the first two leave a slot free. A text offered twice counts once (case-insensitively),
    /// and the prefix itself (in any case) is never returned. Whatever the source, a blocked word or another
    /// entry's alias (a mishearing) is never offered.
    public static func completions(
        prefix: String, previous: [String], snapshot: VocabularySnapshot?, pairs: WordPairModel?,
        completer: (any WordCompleting)?, languages: [String], limit: Int = WordSuggester.limit, now: Date = Date()
    ) async -> [String] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, limit > 0 else { return [] }
        var out: [String] = []
        var seen: Set<String> = []
        let hidden = hiddenKeys(in: snapshot)
        func add(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard out.count < limit, !text.isEmpty, text.lowercased() != typed.lowercased(),
                  !hidden.contains(VocabularyEntry.foldedKey(for: text)), seen.insert(text.lowercased()).inserted
            else { return }
            out.append(text)
        }
        if let snapshot { vocabularyMatches(prefix: typed, in: snapshot, now: now).forEach(add) }
        if let pairs { pairs.complete(prefix: typed, after: previous, limit: limit * 2, now: now).forEach(add) }
        if out.count < limit, let completer {
            for text in await completer.completions(prefix: typed, languages: languages) { add(text) }
        }
        return out
    }

    /// The most likely next words after `previous`, best first. With the vocabulary `snapshot`, blocked words and
    /// aliases are left out (the model is asked for more, so that the slots still fill).
    public static func predictions(
        previous: [String], pairs: WordPairModel?, snapshot: VocabularySnapshot? = nil, limit: Int = WordSuggester.limit,
        now: Date = Date()
    ) -> [String] {
        guard let pairs else { return [] }
        let hidden = hiddenKeys(in: snapshot)
        guard !hidden.isEmpty else { return pairs.predict(after: previous, limit: limit, now: now) }
        return Array(
            pairs.predict(after: previous, limit: WordPairModel.maxNext, now: now)
                .filter { !hidden.contains(VocabularyEntry.foldedKey(for: $0)) }.prefix(max(0, limit)))
    }

    /// The folded keys of every blocked entry and of every alias: texts no output may contain.
    private static func hiddenKeys(in snapshot: VocabularySnapshot?) -> Set<String> {
        guard let snapshot else { return [] }
        var keys: Set<String> = []
        for entry in snapshot.entries {
            if entry.blocked { keys.insert(VocabularyEntry.foldedKey(for: entry.text)) }
            for alias in entry.aliases { keys.insert(VocabularyEntry.foldedKey(for: alias)) }
        }
        return keys
    }

    private static func vocabularyMatches(prefix: String, in snapshot: VocabularySnapshot, now: Date) -> [String] {
        var aliasOwners: [String: Set<UUID>] = [:]
        for entry in snapshot.entries {
            for alias in entry.aliases { aliasOwners[VocabularyEntry.foldedKey(for: alias), default: []].insert(entry.id) }
        }
        let wanted = prefix.lowercased()
        return snapshot.entries.filter { entry in
            guard !entry.blocked else { return false }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.contains(where: \.isWhitespace), text.lowercased().hasPrefix(wanted) else { return false }
            return (aliasOwners[VocabularyEntry.foldedKey(for: text)] ?? []).subtracting([entry.id]).isEmpty
        }
        .sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let (x, y) = (a.effectiveScore(now: now), b.effectiveScore(now: now))
            return x != y ? x > y : a.text < b.text
        }
        .map(\.text)
    }
}
