import Foundation
import Synchronization
import Testing
@testable import LegatoVocabulary

/// A dictionary fake: a word is known in a language when its lowercase form is in that language's set.
struct FakeSpellChecker: SpellChecking {
    var known: [String: Set<String>]
    func isKnown(_ word: String, language: String) async -> Bool { known[language]?.contains(word.lowercased()) ?? false }
    func guesses(for word: String, language: String) async -> [String] { [] }
}

/// Counts how a learner asks: whole texts through the batch lookup, or word by word.
final class CountingSpellChecker: SpellChecking {
    private let inner: FakeSpellChecker
    private let counts = Mutex((batches: 0, singles: 0))
    init(_ inner: FakeSpellChecker) { self.inner = inner }
    var batches: Int { counts.withLock { $0.batches } }
    var singles: Int { counts.withLock { $0.singles } }
    func isKnown(_ word: String, language: String) async -> Bool {
        counts.withLock { $0.singles += 1 }
        return await inner.isKnown(word, language: language)
    }
    func guesses(for word: String, language: String) async -> [String] { [] }
    func knownLanguages(for words: [String], languages: [String]) async -> [String: Set<String>] {
        counts.withLock { $0.batches += 1 }
        return await inner.knownLanguages(for: words, languages: languages)
    }
}

/// A tagger fake: returns the configured names that occur in the text.
struct FakeTagger: EntityTagging {
    var spans: [EntitySpan] = []
    func entities(in text: String, language: String) -> [EntitySpan] { spans.filter { text.contains($0.text) } }
}

struct LearnerHarness {
    let url: URL
    let store: VocabularyStore
    let learner: VocabularyLearner
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_000_000 + 86_400)

    static let de: Set<String> = [
        "ich", "treffe", "heute", "mit", "und", "der", "das", "ist", "bei", "fahre", "nach", "wir", "nutzen", "ki",
        "habe", "äpfel", "berlin", "sag", "bitte", "die", "wohnung",
    ]
    static let en: Set<String> = [
        "we", "met", "with", "today", "and", "the", "ask", "about", "it", "this", "is", "at", "use", "code", "their",
        "there", "berlin", "usb", "nasa", "rust", "bank", "twenty", "one", "ok",
    ]

    init(
        spans: [EntitySpan] = [], languages: [String] = ["de", "en"], known: Set<String> = [],
        spellChecker: (any SpellChecking)? = nil
    ) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-learner-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
        store = VocabularyStore(fileURL: url)
        learner = VocabularyLearner(
            store: store,
            spellChecker: spellChecker ?? FakeSpellChecker(known: ["de": Self.de, "en": Self.en.union(known)]),
            tagger: FakeTagger(spans: spans), languages: languages, now: { Self.t1 })
    }

    func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func snapshot() async throws -> VocabularySnapshot { try await store.snapshot() }

    func observe(_ text: String, locale: String = "en", times n: Int = 1) async {
        for _ in 0..<n { await learner.observe(text: text, locale: Locale(identifier: locale), dictationID: UUID()) }
    }

    func fix(
        _ raw: String, _ cleaned: String, style: CleanupLearningStyle = .verbatim, run: UUID = UUID(), times n: Int = 1,
        suggested: [String] = []
    ) async {
        for i in 0..<n {
            await learner.observeCleanup(
                raw: raw, cleaned: cleaned, style: style, runID: n == 1 ? run : (i == 0 ? run : UUID()),
                locale: Locale(identifier: "en"), suggested: suggested)
        }
    }
}

@Suite struct VocabularyLearnerObserveTests {
    // MARK: promotion thresholds

    @Test func anUnknownWordIsPromotedOnTheThirdDistinctDictationNotBefore() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("ich treffe Zorbax heute", locale: "de", times: 2)
        var snap = try await h.snapshot()
        #expect(snap.entry(forText: "Zorbax") == nil)
        #expect(snap.pendingTerms.first { $0.text == "Zorbax" }?.ids.count == 2)

        await h.observe("ich treffe Zorbax heute", locale: "de")
        snap = try await h.snapshot()
        let entry = try #require(snap.entry(forText: "Zorbax"))
        #expect(entry.source == .history)
        #expect(entry.kind == .term)
        #expect(entry.knownIn == [])
        #expect(entry.recentIDs.count == 3)
        #expect(entry.lastSeen == LearnerHarness.t1)
        #expect(snap.pendingTerms.contains { $0.text == "Zorbax" } == false)
    }

    @Test func aRepeatedDictationIdCountsOnce() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        let id = UUID()
        for _ in 0..<4 {
            await h.learner.observe(text: "we met Zorbax today", locale: Locale(identifier: "en"), dictationID: id)
        }
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingTerms.first { $0.text == "Zorbax" }?.ids == [id])
    }

    @Test func aNameIsPromotedOnTheSecondDictationWithItsKind() async throws {
        let h = LearnerHarness(spans: [EntitySpan(text: "Grünwald", kind: .place)])
        defer { h.cleanup() }
        await h.observe("ich fahre nach Grünwald", locale: "de")
        #expect(try await h.snapshot().entry(forText: "Grünwald") == nil)
        await h.observe("das ist Grünwald", locale: "de")
        let entry = try #require(try await h.snapshot().entry(forText: "Grünwald"))
        #expect(entry.kind == .place)
        #expect(entry.source == .history)
    }

    @Test func aKnownWordTaggedAsANameIsPromotedAndRecordsWhereItIsKnown() async throws {
        let h = LearnerHarness(spans: [EntitySpan(text: "Berlin", kind: .place)])
        defer { h.cleanup() }
        await h.observe("ich fahre nach Berlin", locale: "de", times: 2)
        let entry = try #require(try await h.snapshot().entry(forText: "Berlin"))
        #expect(entry.kind == .place)
        #expect(entry.knownIn == ["de", "en"])
    }

    @Test func aWordKnownInAnyConfiguredLanguageIsNotACandidateWhateverTheLocale() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        // "heute" is German; dictating under the English locale must not make it rare.
        await h.observe("we met heute", locale: "en", times: 5)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingTerms.contains { $0.text.lowercased() == "heute" } == false)
    }

    @Test func aWordIsRareWhenUnknownInEveryConfiguredLanguageEvenUnderTheOtherLocale() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("ich treffe Zorbax heute", locale: "en", times: 3)
        #expect(try await h.snapshot().entry(forText: "Zorbax") != nil)
    }

    @Test func onlyConfiguredLanguagesCountForKnownness() async throws {
        let h = LearnerHarness(languages: ["en"])
        defer { h.cleanup() }
        await h.observe("we met heute", locale: "en", times: 3)
        #expect(try await h.snapshot().entry(forText: "heute") != nil)
    }

    @Test func anAcronymIsACandidateEvenWhenTheDictionaryKnowsIt() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("we use USB today", times: 2)
        #expect(try await h.snapshot().entry(forText: "USB") == nil)
        await h.observe("we use USB today")
        let entry = try #require(try await h.snapshot().entry(forText: "USB"))
        #expect(entry.knownIn == ["en"])
    }

    @Test func aTwoLetterAcronymIsACandidateButASingleLetterAndMixedCaseAreNot() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("wir nutzen KI und A und Ok", locale: "de", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.map(\.text) == ["KI"])
    }

    @Test func aPhraseWithARareTokenIsPromotedOnTheSecondDictation() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("we use Kuber Netties today")
        #expect(try await h.snapshot().entry(forText: "Kuber Netties") == nil)
        await h.observe("we use Kuber Netties today")
        let entry = try #require(try await h.snapshot().entry(forText: "Kuber Netties"))
        #expect(entry.source == .history)
    }

    @Test func aPhraseOfOnlyCommonWordsIsNotACandidate() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("we met with the code today", times: 4)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingTerms.isEmpty)
    }

    @Test func aPhraseNeverEndsOnAKnownLowercaseWord() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("we use Kuber Netties today", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entry(forText: "Netties today") == nil)
        #expect(snap.entry(forText: "use Kuber") == nil)
    }

    // MARK: aliases, entries, blocking

    @Test func aWordThatIsAnAliasOfATermIsNeverPromoted() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Claude", aliases: ["kloud"], now: LearnerHarness.t0)
        await h.observe("ask kloud about it", times: 5)
        let snap = try await h.snapshot()
        #expect(snap.entry(forText: "kloud") == nil)
        #expect(snap.pendingTerms.contains { $0.text == "kloud" } == false)
    }

    @Test func observingAnExistingEntryReinforcesItOncePerId() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Zorbax", now: LearnerHarness.t0)
        let id = UUID()
        await h.learner.observe(text: "we met Zorbax today", locale: Locale(identifier: "en"), dictationID: id)
        await h.learner.observe(text: "we met Zorbax today", locale: Locale(identifier: "en"), dictationID: id)
        let entry = try #require(try await h.snapshot().entry(forText: "Zorbax"))
        #expect(entry.score == 2)
        #expect(entry.lastSeen == LearnerHarness.t1)
        #expect(entry.source == .manual)
        #expect(entry.recentIDs == [id])
    }

    @Test func aBlockedEntryIsNeverRelearnedOrReinforced() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        let entry = try await h.store.add(text: "Zorbax", now: LearnerHarness.t0)
        try await h.store.block(id: entry.id)
        await h.observe("we met Zorbax today", times: 5)
        let snap = try await h.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].blocked)
        #expect(snap.entries[0].score == 1)
        #expect(snap.pendingTerms.contains { $0.text == "Zorbax" } == false)
    }

    @Test func nothingIsLearnedFromTextWithoutRareWords() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("we met today", times: 3)
        await h.observe("", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingTerms.isEmpty)
    }
}

@Suite struct VocabularyLearnerCleanupTests {
    @Test func aFixSeenInTwoDistinctRunsAddsTheAliasAndMarksTheTarget() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("ask kloud about it", "ask Claude about it")
        var snap = try await h.snapshot()
        #expect(snap.entry(forText: "Claude") == nil)
        #expect(snap.pendingFixes.count == 1)

        await h.fix("ask kloud about it", "ask Claude about it")
        snap = try await h.snapshot()
        let entry = try #require(snap.entry(forText: "Claude"))
        #expect(entry.source == .cleanup)
        #expect(entry.aliases == ["kloud"])
        #expect(entry.correctionTarget)
        #expect(snap.pendingFixes.isEmpty)
        #expect(snap.entry(forText: "kloud") == nil)
    }

    @Test func aRepeatedRunIdCountsOnce() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        let run = UUID()
        await h.fix("ask kloud about it", "ask Claude about it", run: run)
        await h.fix("ask kloud about it", "ask Claude about it", run: run)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.first?.ids == [run])
    }

    @Test func aMessageStyleRewriteTeachesNothing() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("ask kloud about it", "ask Claude about it", style: .message, times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test(arguments: [
        ("ich habe 13 Äpfel", "ich habe dreizehn Äpfel"),
        ("ich habe dreizehn Äpfel", "ich habe 13 Äpfel"),
        ("we met twenty one", "we met 21"),
        ("we met 21", "we met twenty one"),
        ("ich habe zweihundertdreiundzwanzig Äpfel", "ich habe 223 Äpfel"),
        ("we met one hundred and five", "we met 105"),
        ("we met 3,5", "we met three point five"),
    ])
    func numberFormattingChangesAreIgnored(_ pair: (String, String)) async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix(pair.0, pair.1, times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aCaseOnlyChangeIsIgnored() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("ask claude about it", "ask Claude about it", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aDiacriticOnlyChangeIsIgnored() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("ich fahre nach Grunwald", "ich fahre nach Grünwald", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aChangeToACommonWordIsIgnored() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("we met their today", "we met there today", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aTargetKnownInOnlyOneConfiguredLanguageIsStillCommon() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("ich treffe heude", "ich treffe heute", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
    }

    @Test func aNameTargetCountsAsRareEvenWhenTheDictionaryKnowsIt() async throws {
        let h = LearnerHarness(spans: [EntitySpan(text: "Berlin", kind: .place)])
        defer { h.cleanup() }
        await h.fix("ich fahre nach Barlin", "ich fahre nach Berlin", times: 2)
        let entry = try #require(try await h.snapshot().entry(forText: "Berlin"))
        #expect(entry.aliases == ["Barlin"])
        #expect(entry.kind == .place)
    }

    @Test func aPhraseTargetCountsAsRare() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("we use klaud kode today", "we use Claude Code today", times: 2)
        let entry = try #require(try await h.snapshot().entry(forText: "Claude Code"))
        #expect(entry.aliases == ["klaud kode"])
    }

    @Test func anAcronymTargetUnknownInLowercaseCountsAsRare() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("we use sapp today", "we use SAP today", times: 2)
        let entry = try #require(try await h.snapshot().entry(forText: "SAP"))
        #expect(entry.aliases == ["sapp"])
    }

    @Test func aTargetThatIsAlreadyATermIsReinforcedOnTheFirstSighting() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Rust", now: LearnerHarness.t0)
        let run = UUID()
        await h.fix("we use rast today", "we use Rust today", run: run)
        let snap = try await h.snapshot()
        let entry = try #require(snap.entry(forText: "Rust"))
        #expect(entry.score == 2)
        #expect(entry.lastSeen == LearnerHarness.t1)
        #expect(entry.recentIDs == [run])
        #expect(entry.aliases == [])
        #expect(snap.pendingFixes.count == 1)
    }

    @Test func aBlockedTargetIsNeverRelearned() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        let entry = try await h.store.add(text: "Claude", now: LearnerHarness.t0)
        try await h.store.block(id: entry.id)
        await h.fix("ask kloud about it", "ask Claude about it", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].aliases == [])
        #expect(snap.entries[0].score == 1)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aFixToAnExistingTargetAddsTheAliasAfterTwoRuns() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Claude", aliases: ["clod"], now: LearnerHarness.t0)
        await h.fix("ask kloud about it", "ask Claude about it", times: 2)
        let entry = try #require(try await h.snapshot().entry(forText: "Claude"))
        #expect(entry.aliases == ["clod", "kloud"])
        #expect(entry.correctionTarget)
        #expect(entry.source == .manual)
    }

    @Test func aMultiWordBlockIsLearnedAsOneFix() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("we use kuber netties today", "we use Kubernetes today", times: 2)
        let entry = try #require(try await h.snapshot().entry(forText: "Kubernetes"))
        #expect(entry.aliases == ["kuber netties"])
    }
}

@Suite struct VocabularyLearnerChoiceTests {
    @Test func aRareChoiceIsPromotedAtOnceWithTheOriginalAsAlias() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.learner.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: false)
        let entry = try #require(try await h.snapshot().entry(forText: "Claude"))
        #expect(entry.source == .choice)
        #expect(entry.aliases == ["kloud"])
        #expect(entry.lastSeen == LearnerHarness.t1)
    }

    @Test func aPlainSpellCheckerSwapOfACommonWordTeachesNothing() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.learner.recordChoice(original: "their", chosen: "there", fromVocabulary: false)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingTerms.isEmpty)
    }

    @Test func aCommonWordChosenFromTheVocabularyIsPromoted() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.learner.recordChoice(original: "bonk", chosen: "bank", fromVocabulary: true)
        let entry = try #require(try await h.snapshot().entry(forText: "bank"))
        #expect(entry.aliases == ["bonk"])
        #expect(entry.knownIn == ["en"])
    }

    @Test func aChoiceReinforcesAnExistingEntryAndMergesTheAlias() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Claude", aliases: ["clod"], now: LearnerHarness.t0)
        await h.learner.recordChoice(original: "kloud", chosen: "claude", fromVocabulary: true)
        let snap = try await h.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].aliases == ["clod", "kloud"])
        #expect(snap.entries[0].score == 2)
        #expect(snap.entries[0].text == "Claude")
    }

    @Test func aChoiceThatOnlyChangesCaseAddsNoAlias() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.learner.recordChoice(original: "claude", chosen: "Claude", fromVocabulary: true)
        let entry = try #require(try await h.snapshot().entry(forText: "Claude"))
        #expect(entry.aliases == [])
    }

    @Test func aBlockedEntryIsNeverRelearnedFromAChoice() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        let entry = try await h.store.add(text: "Claude", now: LearnerHarness.t0)
        try await h.store.block(id: entry.id)
        await h.learner.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: true)
        let snap = try await h.snapshot()
        #expect(snap.entries[0].aliases == [])
        #expect(snap.entries[0].blocked)
    }

    @Test func aMultiWordChoiceCountsAsRare() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.learner.recordChoice(original: "klaud code", chosen: "Claude Code", fromVocabulary: false)
        #expect(try await h.snapshot().entry(forText: "Claude Code") != nil)
    }
}

// MARK: an alias never survives as a sibling entry

@Suite struct VocabularyLearnerAliasSiblingTests {
    @Test func aLearnedEntryEqualToANewAliasIsRemovedByAChoice() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("ask kloud about it", times: 3)
        #expect(try await h.snapshot().entry(forText: "kloud") != nil)

        await h.learner.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: true)
        let snap = try await h.snapshot()
        #expect(snap.entry(forText: "kloud") == nil)
        #expect(snap.entry(forText: "Claude")?.aliases == ["kloud"])
    }

    @Test func aLearnedEntryEqualToANewAliasIsRemovedByACleanupFix() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("ask kloud about it", times: 3)
        await h.fix("ask kloud about it", "ask Claude about it", times: 2)
        let snap = try await h.snapshot()
        #expect(snap.entry(forText: "kloud") == nil)
        #expect(snap.entry(forText: "Claude")?.aliases == ["kloud"])
    }

    @Test func theComparisonIgnoresCaseAndDiacritics() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("ask Kloüd about it", times: 3)
        #expect(try await h.snapshot().entry(forText: "Kloüd") != nil)
        await h.learner.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: true)
        #expect(try await h.snapshot().entry(forText: "Kloüd") == nil)
    }

    @Test func aPendingTermEqualToANewAliasIsDropped() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.observe("ask kloud about it", times: 2)
        #expect(try await h.snapshot().pendingTerms.contains { $0.text == "kloud" })
        await h.learner.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: true)
        #expect(try await h.snapshot().pendingTerms.contains { $0.text == "kloud" } == false)
    }

    @Test func aManualOrPinnedEntryEqualToANewAliasStays() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "kloud", now: LearnerHarness.t0)
        let pinned = try await h.store.add(text: "Zorbax", now: LearnerHarness.t0)
        try await h.store.update { snap in
            if let i = snap.entries.firstIndex(where: { $0.id == pinned.id }) { snap.entries[i].source = .history }
        }
        try await h.store.pin(id: pinned.id)
        await h.learner.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: true)
        await h.learner.recordChoice(original: "zorbax", chosen: "Claude", fromVocabulary: true)
        let snap = try await h.snapshot()
        #expect(snap.entry(forText: "kloud") != nil)
        #expect(snap.entry(forText: "Zorbax") != nil)
    }

    @Test func theWordsOfAnAliasPhraseAreNotPromotedWhileTheyOccurInsideIt() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Kubernetes", aliases: ["kuber netties"], now: LearnerHarness.t0)
        await h.observe("we use kuber netties today", times: 4)
        let snap = try await h.snapshot()
        #expect(snap.entries.map(\.text) == ["Kubernetes"])
        #expect(snap.pendingTerms.isEmpty)
    }

    @Test func aWordOfAnAliasPhraseStillCountsWhenItOccursOutsideIt() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Kubernetes", aliases: ["kuber netties"], now: LearnerHarness.t0)
        await h.observe("we use kuber today", times: 3)
        #expect(try await h.snapshot().entry(forText: "kuber") != nil)
    }
}

// MARK: cleanup rarity (multi-word, number, acronym targets)

@Suite struct VocabularyLearnerCleanupRarityTests {
    let common: Set<String> = ["going", "to", "are", "meet", "see", "you", "march", "on", "said", "okay", "pm", "kilo", "book", "for", "weighs", "it", "long"]

    @Test func aContractionExpansionTeachesNothing() async throws {
        let h = LearnerHarness(known: common)
        defer { h.cleanup() }
        await h.fix("we are gonna meet", "we are going to meet", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aMultiWordTargetNeedsARareTokenAndRareOrCapitalisedEdges() async throws {
        let h = LearnerHarness(known: common)
        defer { h.cleanup() }
        // "Claude" is rare, but the block ends on the known lowercase word "today".
        await h.fix("we ask kloud tuday now", "we ask Claude today now", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test(arguments: [
        ("see you at free p m", "see you at 3 PM"),
        ("on mar tree we meet", "on March 3 we meet"),
        ("it is five kilometer long", "it is 5 km long"),
    ])
    func aTargetWithDigitsUnitsOrTimesTeachesNothing(_ pair: (String, String)) async throws {
        let h = LearnerHarness(known: common)
        defer { h.cleanup() }
        await h.fix(pair.0, pair.1, times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aTimeOrUnitWordWithoutDigitsTeachesNothing() async throws {
        let h = LearnerHarness(known: common.subtracting(["pm"]))
        defer { h.cleanup() }
        await h.fix("book it for p m", "book it for PM", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aBlockWithANumberWordOnTheRawSideTeachesNothing() async throws {
        let h = LearnerHarness(known: common)
        defer { h.cleanup() }
        await h.fix("we met two kloud today", "we met Claude today", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func anAcronymTargetKnownInLowercaseTeachesNothing() async throws {
        let h = LearnerHarness(known: common)
        defer { h.cleanup() }
        await h.fix("we said okay today", "we said OK today", times: 3)
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func anAcronymTargetKnownInLowercaseInAConfiguredLanguageTeachesNothing() async throws {
        let h = LearnerHarness(known: common)
        defer { h.cleanup() }
        await h.fix("we use nasser today", "we use NASA today", times: 3)
        #expect(try await h.snapshot().entries.isEmpty)
    }
}

// MARK: a suggested term is no independent evidence

@Suite struct VocabularyLearnerSuggestedTests {
    @Test func aSubstitutionToASuggestedTermReinforcesNothingAndTeachesNoAlias() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        try await h.store.add(text: "Claude", now: LearnerHarness.t0)
        await h.fix("ask kloud about it", "ask Claude about it", times: 3, suggested: ["claude"])
        let snap = try await h.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].score == 1)
        #expect(snap.entries[0].aliases == [])
        #expect(snap.entries[0].recentIDs.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aSuggestedTermInsideAMultiWordTargetIsSkippedToo() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("we use klaud kode today", "we use Claude Code today", times: 3, suggested: ["Claude Code"])
        let snap = try await h.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.pendingFixes.isEmpty)
    }

    @Test func aFixToATermThatWasNotSuggestedStillLearns() async throws {
        let h = LearnerHarness()
        defer { h.cleanup() }
        await h.fix("ask kloud about it", "ask Claude about it", times: 2, suggested: ["Kubernetes"])
        #expect(try await h.snapshot().entry(forText: "Claude")?.aliases == ["kloud"])
    }
}

// MARK: one batch lookup per text

@Suite struct VocabularyLearnerBatchLookupTests {
    private func counting() -> CountingSpellChecker {
        CountingSpellChecker(FakeSpellChecker(known: ["de": LearnerHarness.de, "en": LearnerHarness.en]))
    }

    @Test func observeChecksAWholeTextInOneBatch() async throws {
        let checker = counting()
        let h = LearnerHarness(spellChecker: checker)
        defer { h.cleanup() }
        await h.observe("we met Zorbax today. ask about it, Quillon", times: 1)
        #expect(checker.batches == 1)
        #expect(checker.singles == 0)
    }

    @Test func observeCleanupChecksAllBlocksInOneBatch() async throws {
        let checker = counting()
        let h = LearnerHarness(spellChecker: checker)
        defer { h.cleanup() }
        await h.fix("ask kloud about rast today", "ask Claude about Rust today")
        #expect(checker.batches == 1)
        #expect(checker.singles == 0)
    }

    @Test func recordChoiceChecksTheTargetInOneBatch() async throws {
        let checker = counting()
        let h = LearnerHarness(spellChecker: checker)
        defer { h.cleanup() }
        await h.learner.recordChoice(original: "klaud kode", chosen: "Claude Code", fromVocabulary: false)
        #expect(checker.batches == 1)
        #expect(checker.singles == 0)
    }
}
