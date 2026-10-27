import Foundation

/// Learns vocabulary terms from what the user dictates, how cleanup fixed it and what they tapped.
///
/// Every signal carries an id and a repeated id counts once. Words are judged against **all** configured
/// languages, whatever locale the session ran in, so a German word dictated under an English locale is not
/// mistaken for a rare one. Learning is best effort: a store failure is swallowed, never thrown into a dictation.
/// A blocked text is never learned again.
///
/// The three signals:
/// - ``observe(text:locale:dictationID:)``: final dictation text. A candidate (a name, a word unknown in every
///   configured language, an all-caps acronym, or a 2-3 word phrase around a rare word) becomes an entry after
///   2 distinct dictations (names, phrases) or 3 (unknown words, acronyms).
/// - ``observeCleanup(raw:cleaned:style:runID:locale:suggested:)``: the same fix in 2 distinct cleanup runs teaches
///   an alias.
/// - ``recordChoice(original:chosen:fromVocabulary:)``: a tapped alternative teaches at once.
public struct VocabularyLearner: Sendable {
    /// Distinct dictations before a name or phrase is promoted.
    public static let namePromotionCount = 2
    /// Distinct dictations before an unknown word or acronym is promoted.
    public static let wordPromotionCount = 3
    /// Distinct cleanup runs before a fix is learned.
    public static let fixPromotionCount = 2

    private let store: VocabularyStore
    private let spellChecker: any SpellChecking
    private let tagger: any EntityTagging
    private let languages: [String]
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - languages: the configured language codes ("de", "en"); a word is common if any of them knows it.
    ///   - now: the clock; tests inject a fixed one.
    public init(
        store: VocabularyStore, spellChecker: any SpellChecking, tagger: any EntityTagging, languages: [String],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.spellChecker = spellChecker
        self.tagger = tagger
        self.languages = languages
        self.now = now
    }

    // MARK: dictation

    /// Looks for candidates in the final text of dictation `dictationID` and promotes those with enough evidence.
    ///
    /// The words of the text are checked against the dictionaries in one batch. A word that occurs inside a
    /// multi-word alias of a term ("kuber netties") is a mishearing of that term, not a candidate.
    public func observe(text: String, locale: Locale, dictationID: UUID) async {
        let chunks = Self.chunks(of: text)
        guard !chunks.isEmpty else { return }
        let language = language(of: locale)
        let spans = tagger.entities(in: text, language: language)
        let aliasPhrases = await aliasPhrases()
        let covered = chunks.map { Self.covered(by: aliasPhrases, in: $0) }
        let anyCovered = covered.contains { $0.contains(true) }
        let known = await lookup(chunks.flatMap { $0 } + spans.flatMap { Self.words(of: $0.text) })
        var candidates = Candidates()

        for span in spans {
            let words = Self.words(of: span.text)
            guard !words.isEmpty else { continue }
            let spanKey = VocabularyEntry.key(for: words.joined(separator: " "))
            if anyCovered, aliasPhrases.contains(where: { (" " + $0 + " ").contains(" " + spanKey + " ") }) { continue }
            candidates.add(
                text: words.joined(separator: " "), kind: span.kind, threshold: Self.namePromotionCount,
                knownIn: words.count == 1 ? known.languages(of: words[0]) : [])
        }

        for (chunk, covered) in zip(chunks, covered) {
            var rare: [Bool] = []
            for (index, word) in chunk.enumerated() {
                let acronym = Self.isAcronym(word)
                let languages = known.languages(of: word)
                let unknown = Self.isWordLike(word) && Self.letterCount(word) >= 3 && languages.isEmpty
                let isRare = !covered[index] && (acronym || unknown)
                rare.append(isRare)
                if isRare {
                    candidates.add(text: word, kind: .term, threshold: Self.wordPromotionCount, knownIn: languages)
                }
            }
            for length in 2...3 where chunk.count >= length {
                for start in 0...(chunk.count - length) {
                    let range = start..<start + length
                    guard range.contains(where: { rare[$0] }) else { continue }
                    guard Self.isPhraseEdge(chunk, rare, start, first: true), Self.isPhraseEdge(chunk, rare, start + length - 1, first: false)
                    else { continue }
                    candidates.add(
                        text: chunk[range].joined(separator: " "), kind: .term, threshold: Self.namePromotionCount, knownIn: [])
                }
            }
        }
        guard !candidates.items.isEmpty else { return }

        let items = candidates.items
        let moment = now()
        _ = try? await store.update(now: moment) { snap in
            let aliasKeys = Set(snap.entries.flatMap(\.aliases).map(VocabularyEntry.foldedKey(for:)))
            for c in items {
                let key = VocabularyEntry.key(for: c.text)
                if aliasKeys.contains(VocabularyEntry.foldedKey(for: c.text)) || snap.isBlocked(c.text) { continue }
                if let i = snap.entries.firstIndex(where: { VocabularyEntry.key(for: $0.text) == key }) {
                    if snap.entries[i].remember(dictationID) {
                        snap.entries[i].score += 1
                        snap.entries[i].lastSeen = moment
                    }
                    continue
                }
                var pending: PendingTerm
                if let p = snap.pendingTerms.firstIndex(where: { VocabularyEntry.key(for: $0.text) == key }) {
                    pending = snap.pendingTerms[p]
                    guard !pending.ids.contains(dictationID) else { continue }
                    pending.ids.append(dictationID)
                    pending.score += 1
                    pending.lastSeen = moment
                    if pending.kind == .term { pending.kind = c.kind }
                    snap.pendingTerms[p] = pending
                } else {
                    pending = PendingTerm(text: c.text, kind: c.kind, ids: [dictationID], score: 1, lastSeen: moment)
                    snap.pendingTerms.append(pending)
                }
                if pending.ids.count >= c.threshold {
                    snap.pendingTerms.removeAll { VocabularyEntry.key(for: $0.text) == key }
                    snap.entries.append(
                        VocabularyEntry(
                            text: pending.text, kind: pending.kind, source: .history, score: pending.score, lastSeen: moment,
                            recentIDs: Array(pending.ids.suffix(VocabularyEntry.recentIDsCapacity)), knownIn: c.knownIn))
                }
            }
        }
    }

    // MARK: cleanup

    /// Learns from what a cleanup run changed. Only ``CleanupLearningStyle/verbatim`` runs count. Each
    /// word-level substitution is kept when
    /// - neither side has a digit or a spelled-out number and the target is no unit or time marker ("3 PM", "5 km");
    /// - it is not a case- or diacritic-only change;
    /// - its target was not one of the `suggested` terms the model was given (it would not be independent
    ///   evidence: the model copied the term from its prompt);
    /// - its target is rare, or already a term. A single word is rare when unknown in every configured language
    ///   or a name; an acronym when its lowercase form is unknown; several words follow the phrase rule of
    ///   ``observe(text:locale:dictationID:)`` (a rare token, and rare or capitalised non-initial edges), so a
    ///   contraction expansion ("gonna" → "going to") teaches nothing.
    ///
    /// The same raw → target in 2 distinct runs adds raw as an alias of the target (creating the target with
    /// source `.cleanup` if needed) and marks it a correction target. A target that already exists is also
    /// reinforced on its first sighting.
    public func observeCleanup(
        raw: String, cleaned: String, style: CleanupLearningStyle, runID: UUID, locale: Locale, suggested: [String] = []
    ) async {
        guard style == .verbatim else { return }
        var blocks: [WordAlignment.Block] = []
        for block in WordAlignment.substitutions(from: raw, to: cleaned) {
            if NumberWords.containsNumber(block.raw) || NumberWords.containsNumber(block.target) { continue }
            if NumberWords.containsUnit(block.target) { continue }
            if Self.fold(block.rawText) == Self.fold(block.targetText) { continue }
            if Self.isSuggested(block.targetText, among: suggested) { continue }
            blocks.append(block)
        }
        guard !blocks.isEmpty else { return }
        let spans = tagger.entities(in: cleaned, language: language(of: locale))
        let known = await lookup(blocks.flatMap(\.target))
        let fixes = blocks.map { block in
            Fix(
                raw: block.rawText, target: block.targetText,
                info: rarity(of: block.targetText, spans: spans, known: known, strictPhrases: true))
        }

        let moment = now()
        _ = try? await store.update(now: moment) { snap in
            for fix in fixes {
                let rawKey = VocabularyEntry.key(for: fix.raw)
                let targetKey = VocabularyEntry.key(for: fix.target)
                if snap.isBlocked(fix.target) { continue }
                func targetIndex() -> Int? { snap.entries.firstIndex { VocabularyEntry.key(for: $0.text) == targetKey } }
                let exists = targetIndex() != nil
                if !exists && !fix.info.rare { continue }
                if let i = targetIndex(), snap.entries[i].remember(runID) {
                    snap.entries[i].score += 1
                    snap.entries[i].lastSeen = moment
                }
                var pending: PendingFix
                if let p = snap.pendingFixes.firstIndex(where: {
                    VocabularyEntry.key(for: $0.raw) == rawKey && VocabularyEntry.key(for: $0.target) == targetKey
                }) {
                    pending = snap.pendingFixes[p]
                    guard !pending.ids.contains(runID) else { continue }
                    pending.ids.append(runID)
                    pending.score += 1
                    pending.lastSeen = moment
                    snap.pendingFixes[p] = pending
                } else {
                    pending = PendingFix(raw: fix.raw, target: fix.target, ids: [runID], score: 1, lastSeen: moment)
                    snap.pendingFixes.append(pending)
                }
                guard pending.ids.count >= Self.fixPromotionCount else { continue }
                snap.pendingFixes.removeAll {
                    VocabularyEntry.key(for: $0.raw) == rawKey && VocabularyEntry.key(for: $0.target) == targetKey
                }
                if !exists {
                    snap.entries.append(
                        VocabularyEntry(
                            text: fix.target, kind: fix.info.kind, source: .cleanup, score: pending.score, lastSeen: moment,
                            recentIDs: Array(pending.ids.suffix(VocabularyEntry.recentIDsCapacity)), knownIn: fix.info.knownIn))
                }
                // The raw side is now a known mishearing: a learned entry of the same text must not stay a term.
                snap.removeLearned(equalToAliases: [fix.raw], exceptTextKey: fix.target)
                if let i = targetIndex() {
                    Self.addAlias(fix.raw, to: &snap.entries[i])
                    snap.entries[i].correctionTarget = true
                }
            }
        }
    }

    // MARK: choice

    /// Learns from a tapped alternative: `chosen` becomes a term at once, with `original` as an alias. It only
    /// counts when `chosen` is rare or `fromVocabulary` is true; swapping one common word for another
    /// ("their" → "there") teaches nothing.
    public func recordChoice(original: String, chosen: String, fromVocabulary: Bool) async {
        let target = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        let spans = tagger.entities(in: target, language: languages.first ?? "en")
        let known = await lookup(Self.words(of: target))
        let info = rarity(of: target, spans: spans, known: known, strictPhrases: false)
        guard info.rare || fromVocabulary else { return }

        let moment = now()
        let key = VocabularyEntry.key(for: target)
        _ = try? await store.update(now: moment) { snap in
            if snap.isBlocked(target) { return }
            let addsAlias = VocabularyEntry.key(for: original) != key
            // The original is now a known mishearing: a learned entry of the same text must not stay a term.
            if addsAlias { snap.removeLearned(equalToAliases: [original], exceptTextKey: target) }
            var entry: VocabularyEntry
            let index = snap.entries.firstIndex { VocabularyEntry.key(for: $0.text) == key }
            if let index {
                entry = snap.entries[index]
                entry.score += 1
                entry.lastSeen = moment
            } else {
                entry = VocabularyEntry(text: target, kind: info.kind, source: .choice, lastSeen: moment, knownIn: info.knownIn)
            }
            if addsAlias { Self.addAlias(original, to: &entry) }
            if let index { snap.entries[index] = entry } else { snap.entries.append(entry) }
        }
    }

    // MARK: rarity

    private struct Rarity {
        var rare: Bool
        var kind: VocabularyEntry.Kind
        var knownIn: [String]
    }

    private struct Fix {
        var raw: String
        var target: String
        var info: Rarity
    }

    /// What the dictionaries said about a batch of words: for each, the configured languages that know it.
    private struct Known {
        var table: [String: Set<String>]
        var configured: [String]

        /// The configured languages whose dictionary knows `word`, in configured order.
        func languages(of word: String) -> [String] { configured.filter { table[word]?.contains($0) == true } }
    }

    /// One batch lookup of `words`, plus the lowercase form of every acronym ("OK" → "ok").
    private func lookup(_ words: [String]) async -> Known {
        let lowercase = words.filter(Self.isAcronym).map { $0.lowercased() }
        let table = await spellChecker.knownLanguagesFolding(words + lowercase, languages: languages)
        return Known(table: table, configured: languages)
    }

    /// Whether `text` is rare. A single word is rare when it is a name in `spans`, unknown in every configured
    /// language, or an acronym (when `strictPhrases`, only if its lowercase form is unknown too). Several words
    /// are rare when `strictPhrases` is false; otherwise they follow the phrase rule of ``observe``.
    private func rarity(of text: String, spans: [EntitySpan], known: Known, strictPhrases: Bool) -> Rarity {
        let words = Self.words(of: text)
        let key = VocabularyEntry.key(for: words.joined(separator: " "))
        let span = spans.first {
            let spanKey = " " + VocabularyEntry.key(for: Self.words(of: $0.text).joined(separator: " ")) + " "
            return spanKey.contains(" " + key + " ")
        }
        let kind = span?.kind ?? .term
        if words.count != 1 {
            guard strictPhrases else { return Rarity(rare: words.count > 1, kind: kind, knownIn: []) }
            let rare = words.map { Self.isAcronym($0) || (Self.isWordLike($0) && Self.letterCount($0) >= 3 && known.languages(of: $0).isEmpty) }
            let isRare = words.count > 1 && rare.contains(true)
                && Self.isPhraseEdge(words, rare, 0, first: true) && Self.isPhraseEdge(words, rare, words.count - 1, first: false)
            return Rarity(rare: isRare, kind: kind, knownIn: [])
        }
        let word = words[0]
        let languages = known.languages(of: word)
        var rare = span != nil || languages.isEmpty
        if Self.isAcronym(word) {
            rare = span != nil || (strictPhrases ? known.languages(of: word.lowercased()).isEmpty : true)
        }
        return Rarity(rare: rare, kind: kind, knownIn: languages)
    }

    private func language(of locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? languages.first ?? "en"
    }

    /// The multi-word aliases of the vocabulary, as comparison keys of space-joined words.
    private func aliasPhrases() async -> [String] {
        guard let snapshot = try? await store.snapshot() else { return [] }
        return snapshot.entries.flatMap(\.aliases).compactMap { alias in
            let words = Self.words(of: alias)
            return words.count > 1 ? VocabularyEntry.key(for: words.joined(separator: " ")) : nil
        }
    }

    /// For each word of `chunk`, whether it sits inside an occurrence of one of the alias `phrases`.
    private static func covered(by phrases: [String], in chunk: [String]) -> [Bool] {
        var covered = [Bool](repeating: false, count: chunk.count)
        let lowered = chunk.map { VocabularyEntry.key(for: $0) }
        for phrase in phrases {
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.count <= lowered.count else { continue }
            for start in 0...(lowered.count - parts.count) where Array(lowered[start..<start + parts.count]) == parts {
                for i in start..<start + parts.count { covered[i] = true }
            }
        }
        return covered
    }

    /// Whether `target` is, or contains as whole words, one of the `suggested` terms.
    private static func isSuggested(_ target: String, among suggested: [String]) -> Bool {
        let padded = " " + words(of: fold(target)).joined(separator: " ") + " "
        return suggested.contains { term in
            let words = words(of: fold(term)).joined(separator: " ")
            return !words.isEmpty && padded.contains(" " + words + " ")
        }
    }

    // MARK: candidates

    private struct Candidate {
        var text: String
        var kind: VocabularyEntry.Kind
        var threshold: Int
        var knownIn: [String]
    }

    /// The candidates of one text, merged by comparison key: a name that is also an unknown word keeps its kind
    /// and the lower threshold.
    private struct Candidates {
        private(set) var items: [Candidate] = []

        mutating func add(text: String, kind: VocabularyEntry.Kind, threshold: Int, knownIn: [String]) {
            let key = VocabularyEntry.key(for: text)
            if let i = items.firstIndex(where: { VocabularyEntry.key(for: $0.text) == key }) {
                if kind != .term { items[i].kind = kind }
                items[i].threshold = min(items[i].threshold, threshold)
                return
            }
            items.append(Candidate(text: text, kind: kind, threshold: threshold, knownIn: knownIn))
        }
    }

    /// A phrase may start or end on a rare word, or on a capitalised word that doesn't open the chunk; it never
    /// starts or ends on a known lowercase word or a lone capital.
    private static func isPhraseEdge(_ chunk: [String], _ rare: [Bool], _ index: Int, first: Bool) -> Bool {
        if rare[index] { return true }
        return index > 0 && chunk[index].first?.isUppercase == true && letterCount(chunk[index]) >= 2
    }

    // MARK: text helpers

    /// The words of `text` split into chunks at sentence punctuation and line breaks, edge punctuation trimmed.
    private static func chunks(of text: String) -> [[String]] {
        let breaks = CharacterSet(charactersIn: ".!?,;:()[]\n\r…")
        return text.components(separatedBy: breaks).map(words(of:)).filter { !$0.isEmpty }
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            var chars = Substring(piece)
            while let f = chars.first, !(f.isLetter || f.isNumber) { chars.removeFirst() }
            while let l = chars.last, !(l.isLetter || l.isNumber) { chars.removeLast() }
            return chars.isEmpty ? nil : String(chars)
        }
    }

    private static func letterCount(_ word: String) -> Int { word.filter(\.isLetter).count }

    /// Letters, and inner hyphens or apostrophes only: no digits.
    private static func isWordLike(_ word: String) -> Bool {
        word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }
    }

    /// Two or more letters, all uppercase, nothing else.
    private static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Lowercase, diacritics removed, for the case- and diacritic-only test.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func addAlias(_ alias: String, to entry: inout VocabularyEntry) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = VocabularyEntry.key(for: trimmed)
        guard !trimmed.isEmpty, key != VocabularyEntry.key(for: entry.text),
            !entry.aliases.contains(where: { VocabularyEntry.key(for: $0) == key })
        else { return }
        entry.aliases.append(trimmed)
    }
}
