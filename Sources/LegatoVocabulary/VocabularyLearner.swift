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
/// - ``observeCleanup(raw:cleaned:style:runID:locale:)``: the same fix in 2 distinct cleanup runs teaches an alias.
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
    public func observe(text: String, locale: Locale, dictationID: UUID) async {
        let chunks = Self.chunks(of: text)
        guard !chunks.isEmpty else { return }
        let language = language(of: locale)
        var cache = KnownCache()
        var candidates = Candidates()

        for span in tagger.entities(in: text, language: language) {
            let words = Self.words(of: span.text)
            guard !words.isEmpty else { continue }
            let known = words.count == 1 ? await knownIn(words[0], cache: &cache) : []
            candidates.add(text: words.joined(separator: " "), kind: span.kind, threshold: Self.namePromotionCount, knownIn: known)
        }

        for chunk in chunks {
            var rare: [Bool] = []
            for word in chunk {
                let acronym = Self.isAcronym(word)
                let known = await knownIn(word, cache: &cache)
                let unknown = Self.isWordLike(word) && Self.letterCount(word) >= 3 && known.isEmpty
                rare.append(acronym || unknown)
                if acronym || unknown {
                    candidates.add(text: word, kind: .term, threshold: Self.wordPromotionCount, knownIn: known)
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
            let aliasKeys = Set(snap.entries.flatMap(\.aliases).map(VocabularyEntry.key(for:)))
            for c in items {
                let key = VocabularyEntry.key(for: c.text)
                if aliasKeys.contains(key) || snap.isBlocked(c.text) { continue }
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
    /// word-level substitution is kept when it is not a number-format change and not a case- or diacritic-only
    /// change, and its target is rare (unknown everywhere, a name, a phrase or an acronym) or already a term.
    /// The same raw → target in 2 distinct runs adds raw as an alias of the target (creating the target with
    /// source `.cleanup` if needed) and marks it a correction target. A target that already exists is also
    /// reinforced on its first sighting.
    public func observeCleanup(raw: String, cleaned: String, style: CleanupLearningStyle, runID: UUID, locale: Locale) async {
        guard style == .verbatim else { return }
        var fixes: [Fix] = []
        var spans: [EntitySpan]?
        var cache = KnownCache()
        for block in WordAlignment.substitutions(from: raw, to: cleaned) {
            if NumberWords.isPurelyNumeric(block.raw) || NumberWords.isPurelyNumeric(block.target) { continue }
            if Self.fold(block.rawText) == Self.fold(block.targetText) { continue }
            if spans == nil { spans = tagger.entities(in: cleaned, language: language(of: locale)) }
            let info = await rarity(of: block.targetText, spans: spans ?? [], cache: &cache)
            fixes.append(Fix(raw: block.rawText, target: block.targetText, info: info))
        }
        guard !fixes.isEmpty else { return }

        let moment = now()
        let ids = fixes
        _ = try? await store.update(now: moment) { snap in
            for fix in ids {
                let rawKey = VocabularyEntry.key(for: fix.raw)
                let targetKey = VocabularyEntry.key(for: fix.target)
                if snap.isBlocked(fix.target) { continue }
                var index = snap.entries.firstIndex { VocabularyEntry.key(for: $0.text) == targetKey }
                if index == nil && !fix.info.rare { continue }
                if let i = index, snap.entries[i].remember(runID) {
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
                if index == nil {
                    snap.entries.append(
                        VocabularyEntry(
                            text: fix.target, kind: fix.info.kind, source: .cleanup, score: pending.score, lastSeen: moment,
                            recentIDs: Array(pending.ids.suffix(VocabularyEntry.recentIDsCapacity)), knownIn: fix.info.knownIn))
                    index = snap.entries.count - 1
                }
                if let i = index {
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
        var cache = KnownCache()
        let spans = tagger.entities(in: target, language: languages.first ?? "en")
        let info = await rarity(of: target, spans: spans, cache: &cache)
        guard info.rare || fromVocabulary else { return }

        let moment = now()
        let key = VocabularyEntry.key(for: target)
        _ = try? await store.update(now: moment) { snap in
            if snap.isBlocked(target) { return }
            var entry: VocabularyEntry
            let index = snap.entries.firstIndex { VocabularyEntry.key(for: $0.text) == key }
            if let index {
                entry = snap.entries[index]
                entry.score += 1
                entry.lastSeen = moment
            } else {
                entry = VocabularyEntry(text: target, kind: info.kind, source: .choice, lastSeen: moment, knownIn: info.knownIn)
            }
            if VocabularyEntry.key(for: original) != key { Self.addAlias(original, to: &entry) }
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

    /// Known-ness lookups are remembered per call, so a word repeated in a text is checked once.
    private struct KnownCache {
        var known: [String: [String]] = [:]
    }

    /// The configured languages whose dictionary knows `word`, in configured order.
    private func knownIn(_ word: String, cache: inout KnownCache) async -> [String] {
        if let hit = cache.known[word] { return hit }
        var out: [String] = []
        let startsUpper = word.first?.isUppercase == true && word != word.uppercased()
        for language in languages {
            var known = await spellChecker.isKnown(word, language: language)
            if !known, startsUpper { known = await spellChecker.isKnown(word.lowercased(), language: language) }
            if known { out.append(language) }
        }
        cache.known[word] = out
        return out
    }

    /// Whether `text` is rare: several words, an acronym, a name in `spans`, or a single word unknown everywhere.
    private func rarity(of text: String, spans: [EntitySpan], cache: inout KnownCache) async -> Rarity {
        let words = Self.words(of: text)
        let key = VocabularyEntry.key(for: words.joined(separator: " "))
        let span = spans.first {
            let spanKey = " " + VocabularyEntry.key(for: Self.words(of: $0.text).joined(separator: " ")) + " "
            return spanKey.contains(" " + key + " ")
        }
        let kind = span?.kind ?? .term
        if words.count != 1 { return Rarity(rare: words.count > 1, kind: kind, knownIn: []) }
        let known = await knownIn(words[0], cache: &cache)
        let rare = span != nil || Self.isAcronym(words[0]) || known.isEmpty
        return Rarity(rare: rare, kind: kind, knownIn: known)
    }

    private func language(of locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? languages.first ?? "en"
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
