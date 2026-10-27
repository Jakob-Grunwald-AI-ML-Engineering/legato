import Foundation
import Testing
@testable import LegatoVocabulary

@Suite struct HintSelectorTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400
    let selector = HintSelector(languages: ["de", "en"])

    /// A learned entry that is rare by default (known nowhere).
    func term(
        _ text: String, kind: VocabularyEntry.Kind = .term, source: VocabularyEntry.Source = .history, score: Double = 1,
        age: TimeInterval = 0, knownIn: [String] = [], correctionTarget: Bool = false, pinned: Bool = false,
        blocked: Bool = false, aliases: [String] = [], spellings: [String] = []
    ) -> VocabularyEntry {
        VocabularyEntry(
            text: text, kind: kind, source: source, score: score, lastSeen: Self.now.addingTimeInterval(-age),
            knownIn: knownIn, correctionTarget: correctionTarget, pinned: pinned, blocked: blocked, aliases: aliases,
            spellings: spellings)
    }

    func texts(_ entries: [VocabularyEntry], sink: VocabularyHintSink = .appleSpeech, limit: Int = 50, using s: HintSelector? = nil) -> [String] {
        (s ?? selector).hints(from: VocabularySnapshot(entries: entries), for: sink, limit: limit, now: Self.now).map(\.text)
    }

    // MARK: eligibility

    @Test func aBlockedEntryIsNeverHintedEvenWhenManualOrPinned() {
        let all = [term("Zorbax", blocked: true), term("Quillon", source: .manual, pinned: true, blocked: true)]
        #expect(texts(all).isEmpty)
    }

    @Test func aManualEntryIsHintedEvenWhenItIsAKnownWord() {
        #expect(texts([term("Rust", source: .manual, knownIn: ["de", "en"])]) == ["Rust"])
    }

    @Test func aPinnedEntryIsHintedEvenWhenItIsAKnownLearnedWord() {
        #expect(texts([term("Brücke", knownIn: ["de", "en"], pinned: true)]) == ["Brücke"])
    }

    @Test func aLearnedWordKnownInEveryLanguageIsNeverHintedEvenAsACorrectionTarget() {
        #expect(texts([term("Banken", knownIn: ["de", "en"], correctionTarget: true)]).isEmpty)
    }

    @Test func aLearnedWordKnownInAnyConfiguredLanguageIsCommon() {
        #expect(texts([term("Fenster", knownIn: ["de"])]).isEmpty)
        #expect(texts([term("Window", knownIn: ["en"])]).isEmpty)
    }

    @Test func aLearnedWordUnknownEverywhereIsRare() {
        #expect(texts([term("Zorbax")]) == ["Zorbax"])
    }

    @Test func aLearnedNameIsHintedEvenWhenKnown() {
        let names = [
            term("Berlin", kind: .place, knownIn: ["de", "en"]),
            term("Anna", kind: .person, knownIn: ["de", "en"]),
            term("Mozilla", kind: .organisation, knownIn: ["de", "en"]),
        ]
        #expect(Set(texts(names)) == ["Berlin", "Anna", "Mozilla"])
    }

    @Test func aLearnedPhraseIsHintedEvenWhenItsWordsAreKnown() {
        #expect(texts([term("Open Source", knownIn: ["de", "en"])]) == ["Open Source"])
    }

    @Test func aLearnedAcronymIsHintedEvenWhenKnown() {
        #expect(texts([term("NASA", knownIn: ["de", "en"])]) == ["NASA"])
    }

    @Test func rarityFollowsTheSelectorsLanguages() {
        let known = term("Fenster", knownIn: ["de"])
        #expect(texts([known], using: HintSelector(languages: ["de"])).isEmpty)
        #expect(texts([known], using: HintSelector(languages: ["de", "en"])).isEmpty)
        #expect(texts([known], using: HintSelector(languages: ["en"])) == ["Fenster"])
    }

    // MARK: order, caps, floors

    @Test func pinnedComeFirstThenCorrectionTargetsThenByEffectiveScore() {
        let all = [
            term("Low", score: 1),
            term("High", score: 5),
            term("Corrected", score: 1, correctionTarget: true),
            term("Pinned", score: 1, pinned: true),
            term("Mid", score: 3),
        ]
        #expect(texts(all) == ["Pinned", "Corrected", "High", "Mid", "Low"])
    }

    @Test func theEffectiveScoreDecaysWithAge() {
        let all = [
            term("OldButBig", score: 4, age: 60 * Self.day),  // 4 × 0.25 = 1
            term("NewAndSmall", score: 2, age: 0),
        ]
        #expect(texts(all) == ["NewAndSmall", "OldButBig"])
    }

    @Test func theHalfLifeIsConfigurable() {
        let all = [term("OldButBig", score: 4, age: 10 * Self.day), term("NewAndSmall", score: 2)]
        let fast = HintSelector(languages: ["de", "en"], halfLife: 5 * Self.day)  // 4 × 0.25 = 1 < 2
        let slow = HintSelector(languages: ["de", "en"], halfLife: 100 * Self.day)  // ≈ 3.7 > 2
        #expect(texts(all, using: fast) == ["NewAndSmall", "OldButBig"])
        #expect(texts(all, using: slow) == ["OldButBig", "NewAndSmall"])
    }

    @Test func theLimitCapsTheList() {
        let all = (0..<60).map { term("Term\($0)x", score: Double($0 + 1)) }
        #expect(texts(all, limit: 50).count == 50)
        #expect(texts(all, limit: 50).first == "Term59x")
        #expect(texts(all, limit: 5).count == 5)
        #expect(texts(all, limit: 0).isEmpty)
    }

    @Test func floorsApplyBeforeTheCapSoShortTermsDoNotUseUpSlots() {
        let short = (0..<3).map { term("A\($0)", score: 100) }  // two characters, not an acronym
        let rest = (0..<4).map { term("Longer\($0)", score: 1) }
        let out = texts(short + rest, sink: .nemotron, limit: 4)
        #expect(out.count == 4)
        #expect(out.allSatisfy { $0.hasPrefix("Longer") })
    }

    @Test func aTwoLetterAcronymPassesForAppleSpeechAndCleanupButNotNemotron() {
        let eu = [term("EU", knownIn: ["de", "en"], pinned: true)]
        #expect(texts(eu, sink: .nemotron).isEmpty)
        #expect(texts(eu, sink: .appleSpeech) == ["EU"])
        #expect(texts(eu, sink: .cleanup) == ["EU"])
    }

    @Test func aTwoLetterWordThatIsNotAnAcronymPassesNoSink() {
        let all = [term("Eu", pinned: true), term("go", source: .manual), term("E1", pinned: true)]
        for sink in VocabularyHintSink.allCases { #expect(texts(all, sink: sink).isEmpty) }
    }

    @Test func aThreeLetterTermPassesEverySink() {
        for sink in VocabularyHintSink.allCases { #expect(texts([term("Zob")], sink: sink) == ["Zob"]) }
    }

    // MARK: aliases and spellings

    @Test func aliasesNeverAppearInAnySinkAndSpellingsDo() {
        let e = term("Claude", aliases: ["kloud", "clod"], spellings: ["Claud"])
        for sink in VocabularyHintSink.allCases {
            let hints = HintSelector(languages: ["de", "en"]).hints(from: VocabularySnapshot(entries: [e]), for: sink, now: Self.now)
            #expect(hints == [SelectedHint(text: "Claude", spellings: ["Claud"])])
            let all = hints.flatMap { [$0.text] + $0.spellings }
            #expect(all.contains("kloud") == false)
            #expect(all.contains("clod") == false)
        }
    }

    @Test func anAliasOnlyEntryOfAnotherTermIsNotListedAsATerm() {
        let hints = texts([term("Claude", aliases: ["kloud"])])
        #expect(hints == ["Claude"])
    }

    // MARK: cleanup terms

    /// A dictionary in which "cloud", "clause" and the German "Mauer" are ordinary words.
    static let dictionary = FakeSpellChecker(known: [
        "en": ["cloud", "clause", "computing", "ask", "about", "it", "a", "demo", "the", "is", "void"],
        "de": ["mauer", "die", "ist", "hoch"],
    ])

    func cleanup(
        _ text: String, _ entries: [VocabularyEntry], limit: Int = 20, spell: FakeSpellChecker = FakeSpellChecker(known: [:])
    ) async -> [String] {
        await selector.cleanupTerms(
            for: text, from: VocabularySnapshot(entries: entries), spellChecker: spell, limit: limit, now: Self.now)
    }

    @Test func cleanupTermsAreThePinnedTermsPlusTheHitsInTheText() async {
        let all = [
            term("Claude", score: 2),
            term("Kubernetes", score: 5),
            term("Zorbax", pinned: true),
        ]
        #expect(await cleanup("ask Claude about it", all) == ["Zorbax", "Claude"])
    }

    @Test func nonHitNonPinnedTermsAreExcluded() async {
        #expect(await cleanup("nothing relevant here", [term("Claude"), term("Kubernetes")]).isEmpty)
    }

    @Test func anAliasHitSelectsTheTermNotTheAlias() async {
        #expect(await cleanup("ask kloud about it", [term("Claude", aliases: ["kloud"])]) == ["Claude"])
    }

    @Test func aHitOnASpellingSelectsTheTerm() async {
        #expect(await cleanup("wir fahren nach Gruenwald", [term("Grünwald", spellings: ["Gruenwald"])]) == ["Grünwald"])
    }

    @Test func pinnedTermsTakeCleanupSlotsFirstUnderTheCap() async {
        let pinned = (0..<3).map { term("Pin\($0)x", pinned: true) }
        let hit = [term("Claude")]
        #expect(await cleanup("ask Claude", pinned + hit, limit: 3).count == 3)
        #expect(await cleanup("ask Claude", pinned + hit, limit: 3).allSatisfy { $0.hasPrefix("Pin") })
        #expect(await cleanup("ask Claude", pinned + hit, limit: 4).last == "Claude")
        #expect(await cleanup("ask Claude", pinned + hit, limit: 0).isEmpty)
    }

    @Test func cleanupDefaultsToATwentyTermCap() async {
        let pinned = (0..<30).map { term("Pin\($0)x", pinned: true) }
        let out = await selector.cleanupTerms(
            for: "", from: VocabularySnapshot(entries: pinned), spellChecker: Self.dictionary, now: Self.now)
        #expect(out.count == 20)
    }

    @Test func cleanupHitsFollowTheSameEligibilityAsHints() async {
        let all = [
            term("Claude", blocked: true),
            term("Brücke", knownIn: ["de", "en"]),
            term("Rust", source: .manual, knownIn: ["de", "en"]),
        ]
        #expect(await cleanup("Claude baut eine Brücke aus Rust", all) == ["Rust"])
    }

    @Test func cleanupAcceptsATwoLetterAcronymHit() async {
        #expect(await cleanup("die EU beschließt", [term("EU", knownIn: ["de", "en"])]) == ["EU"])
    }

    @Test func hintsDefaultToFiftyTerms() async {
        let all = (0..<70).map { term("Term\($0)x") }
        #expect(selector.hints(from: VocabularySnapshot(entries: all), for: .nemotron, now: Self.now).count == 50)
    }

    // MARK: cleanup terms must not list common words that merely sound like a term

    @Test func aCommonEnglishWordThatSoundsLikeATermIsNotListed() async {
        let claude = [term("Claude")]
        #expect(await cleanup("a cloud computing demo", claude, spell: Self.dictionary).isEmpty)
        #expect(await cleanup("the clause is void", claude, spell: Self.dictionary).isEmpty)
    }

    @Test func aCommonGermanWordThatSoundsLikeATermIsNotListed() async {
        #expect(await cleanup("die Mauer ist hoch", [term("Maier")], spell: Self.dictionary).isEmpty)
    }

    @Test func aMishearingNobodyKnowsIsStillListed() async {
        #expect(await cleanup("ask kloud about it", [term("Claude")], spell: Self.dictionary) == ["Claude"])
        #expect(await cleanup("wir sehen die Meier dort", [term("Maier")], spell: Self.dictionary) == ["Maier"])
    }

    @Test func oneUnknownWordOfAMultiWordSpanIsEnough() async {
        #expect(await cleanup("we use kuber netties today", [term("Kubernetes")], spell: Self.dictionary) == ["Kubernetes"])
    }

    @Test func anExactFormIsListedEvenWhenItIsAnOrdinaryWord() async {
        #expect(await cleanup("a cloud computing demo", [term("Cloud", source: .manual)], spell: Self.dictionary) == ["Cloud"])
        #expect(await cleanup("a cloud computing demo", [term("Claude", aliases: ["cloud"])], spell: Self.dictionary) == ["Claude"])
        #expect(await cleanup("the clause is void", [term("Sonne", spellings: ["Clause"])], spell: Self.dictionary) == ["Sonne"])
    }

    // MARK: an alias is never listed as a term of its own

    @Test func anEntryWhoseTextIsAnotherEntrysAliasIsNeverHinted() {
        let all = [term("kloud"), term("Claude", aliases: ["Kloud"]), term("Muller"), term("Zorbax", aliases: ["Müller"])]
        for sink in VocabularyHintSink.allCases { #expect(Set(texts(all, sink: sink)) == ["Claude", "Zorbax"]) }
    }

    @Test func aManualEntryEqualToAnotherEntrysAliasIsNotHintedEither() {
        let all = [term("kloud", source: .manual), term("Claude", aliases: ["kloud"])]
        #expect(texts(all) == ["Claude"])
    }

    @Test func anEntryEqualToAnAliasIsNotAmongTheCleanupTerms() async {
        let all = [term("kloud"), term("Claude", aliases: ["kloud"])]
        #expect(await cleanup("ask kloud about it", all, spell: Self.dictionary) == ["Claude"])
        #expect(await cleanup("ask about it", [term("kloud", pinned: true), term("Claude", aliases: ["kloud"])]) == [])
    }
}
