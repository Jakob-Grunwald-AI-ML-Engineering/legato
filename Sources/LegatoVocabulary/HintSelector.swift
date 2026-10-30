import Foundation

/// Chooses which vocabulary terms are worth sending to a speech engine or the cleanup model.
///
/// Eligibility, top-down:
/// 1. A **blocked** entry is never hinted.
/// 2. A **pinned** or **manual** entry is always hinted; the user chose it.
/// 3. A **learned** entry is hinted only if it is rare: unknown to the spell checker in **every** configured
///    language, or a name (person, place, organisation), or a phrase of two or more words, or an acronym.
///    A single word known in any configured language is never hinted, even as a correction target.
///
/// An entry whose text equals another entry's alias (ignoring case and diacritics) is never output, whatever
/// its source: the alias marks it as a mishearing.
///
/// Every sink then applies its length floor **before** the cap (see ``VocabularyHintSink``), and the list is
/// ordered pinned first, then correction targets, then by effective score (`score × 0.5^(age / halfLife)`).
/// Aliases (known mishearings) never appear in any output; spellings do.
public struct HintSelector: Sendable {
    private let languages: [String]
    private let halfLife: TimeInterval

    /// - Parameters:
    ///   - languages: the configured language codes; a learned word is common when `knownIn` covers all of them.
    ///   - halfLife: how fast a score fades; thirty days by default.
    public init(languages: [String], halfLife: TimeInterval = Decay.defaultHalfLife) {
        self.languages = languages
        self.halfLife = halfLife
    }

    /// The best `limit` hints for `sink`: eligible, past the sink's floor, in rank order.
    public func hints(
        from snapshot: VocabularySnapshot, for sink: VocabularyHintSink, limit: Int = 50, now: Date = Date()
    ) -> [SelectedHint] {
        guard limit > 0 else { return [] }
        return ranked(eligibleEntries(in: snapshot, sink: sink), now: now)
            .prefix(sink == .soniox ? min(limit, 100) : limit)
            .map { SelectedHint(text: $0.text, spellings: $0.spellings) }
    }

    /// The terms to list for the cleanup model given the text it will clean: pinned terms first, then the
    /// eligible terms the ``TermMatcher`` hits in `text` (best hit first), at most `limit`. Terms that neither
    /// are pinned nor appear in the text are left out.
    ///
    /// The prompt tells the model to write a sound-alike exactly as the listed term, so a fuzzy hit on an
    /// ordinary word ("cloud" for "Claude") would corrupt the text. A hit therefore counts only when an exact
    /// form (text, spelling or alias) matches, or when at least one word of the matched span is unknown to
    /// `spellChecker` in every configured language: a real mishearing is usually not a word.
    public func cleanupTerms(
        for text: String, from snapshot: VocabularySnapshot, spellChecker: any SpellChecking, limit: Int = 20,
        now: Date = Date()
    ) async -> [String] {
        guard limit > 0 else { return [] }
        let eligible = eligibleEntries(in: snapshot, sink: .cleanup)
        let pinned = ranked(eligible.filter(\.pinned), now: now)
        var out = pinned.map(\.text)
        let others = eligible.filter { !$0.pinned }
        if out.count < limit, !others.isEmpty {
            let byID = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let matcher = TermMatcher(terms: others.map(TermMatcher.Term.init))
            let hits = matcher.hits(in: text)
            let words = TermMatcher.words(in: text)
            let inexact = Array(Set(hits.filter { $0.score < 1 }.flatMap { words[$0.range] }))
            let known = inexact.isEmpty ? [:] : await spellChecker.knownLanguagesFolding(inexact, languages: languages)
            for match in hits {
                let counts = match.score >= 1 || words[match.range].contains { (known[$0] ?? []).isEmpty }
                if counts, let entry = byID[match.termID], !out.contains(entry.text) { out.append(entry.text) }
            }
        }
        return Array(out.prefix(limit))
    }

    // MARK: rules

    /// The entries that may go to `sink`: eligible, past its length floor and not another entry's alias.
    private func eligibleEntries(in snapshot: VocabularySnapshot, sink: VocabularyHintSink) -> [VocabularyEntry] {
        var aliasOwners: [String: Set<UUID>] = [:]
        for entry in snapshot.entries {
            for alias in entry.aliases { aliasOwners[VocabularyEntry.foldedKey(for: alias), default: []].insert(entry.id) }
        }
        return snapshot.entries.filter { entry in
            guard isEligible(entry), passesFloor(entry.text, sink: sink) else { return false }
            let owners = aliasOwners[VocabularyEntry.foldedKey(for: entry.text)] ?? []
            return owners.subtracting([entry.id]).isEmpty
        }
    }

    private func isEligible(_ entry: VocabularyEntry) -> Bool {
        if entry.blocked { return false }
        if entry.pinned || entry.source == .manual { return true }
        return isRare(entry)
    }

    private func isRare(_ entry: VocabularyEntry) -> Bool {
        let unknownEverywhere = !languages.contains { entry.knownIn.contains($0) }
        return unknownEverywhere || entry.kind != .term || Self.wordCount(entry.text) >= 2 || Self.isAcronym(entry.text)
    }

    /// Nemotron takes 3 letters or more; the other sinks also take a 2-letter all-caps acronym.
    private func passesFloor(_ text: String, sink: VocabularyHintSink) -> Bool {
        let letters = text.filter(\.isLetter).count
        if letters >= 3 { return true }
        return sink != .nemotron && letters == 2 && Self.isAcronym(text)
    }

    private func ranked(_ entries: [VocabularyEntry], now: Date) -> [VocabularyEntry] {
        entries.map { (entry: $0, score: $0.effectiveScore(now: now, halfLife: halfLife)) }
            .sorted { a, b in
                if a.entry.pinned != b.entry.pinned { return a.entry.pinned }
                if a.entry.correctionTarget != b.entry.correctionTarget { return a.entry.correctionTarget }
                if a.score != b.score { return a.score > b.score }
                return a.entry.text < b.entry.text
            }
            .map(\.entry)
    }

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Two or more letters, all uppercase, nothing else.
    private static func isAcronym(_ text: String) -> Bool {
        text.count >= 2 && text.allSatisfy { $0.isLetter && $0.isUppercase }
    }
}
