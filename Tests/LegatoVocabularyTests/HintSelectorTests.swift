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

    @Test func aLearnedWordKnownInOnlySomeLanguagesIsRare() {
        #expect(texts([term("Fenster", knownIn: ["de"])]) == ["Fenster"])
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
        #expect(texts([known], using: HintSelector(languages: ["de", "en"])) == ["Fenster"])
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

    func cleanup(_ text: String, _ entries: [VocabularyEntry], limit: Int = 20) -> [String] {
        selector.cleanupTerms(for: text, from: VocabularySnapshot(entries: entries), limit: limit, now: Self.now)
    }

    @Test func cleanupTermsAreThePinnedTermsPlusTheHitsInTheText() {
        let all = [
            term("Claude", score: 2),
            term("Kubernetes", score: 5),
            term("Zorbax", pinned: true),
        ]
        #expect(cleanup("ask Claude about it", all) == ["Zorbax", "Claude"])
    }

    @Test func nonHitNonPinnedTermsAreExcluded() {
        #expect(cleanup("nothing relevant here", [term("Claude"), term("Kubernetes")]).isEmpty)
    }

    @Test func anAliasHitSelectsTheTermNotTheAlias() {
        #expect(cleanup("ask kloud about it", [term("Claude", aliases: ["kloud"])]) == ["Claude"])
    }

    @Test func aHitOnASpellingSelectsTheTerm() {
        #expect(cleanup("wir fahren nach Gruenwald", [term("Grünwald", spellings: ["Gruenwald"])]) == ["Grünwald"])
    }

    @Test func pinnedTermsTakeCleanupSlotsFirstUnderTheCap() {
        let pinned = (0..<3).map { term("Pin\($0)x", pinned: true) }
        let hit = [term("Claude")]
        #expect(cleanup("ask Claude", pinned + hit, limit: 3).count == 3)
        #expect(cleanup("ask Claude", pinned + hit, limit: 3).allSatisfy { $0.hasPrefix("Pin") })
        #expect(cleanup("ask Claude", pinned + hit, limit: 4).last == "Claude")
        #expect(cleanup("ask Claude", pinned + hit, limit: 0).isEmpty)
    }

    @Test func cleanupDefaultsToATwentyTermCap() {
        let pinned = (0..<30).map { term("Pin\($0)x", pinned: true) }
        let out = selector.cleanupTerms(for: "", from: VocabularySnapshot(entries: pinned), now: Self.now)
        #expect(out.count == 20)
    }

    @Test func cleanupHitsFollowTheSameEligibilityAsHints() {
        let all = [
            term("Claude", blocked: true),
            term("Brücke", knownIn: ["de", "en"]),
            term("Rust", source: .manual, knownIn: ["de", "en"]),
        ]
        #expect(cleanup("Claude baut eine Brücke aus Rust", all) == ["Rust"])
    }

    @Test func cleanupAcceptsATwoLetterAcronymHit() {
        #expect(cleanup("die EU beschließt", [term("EU", knownIn: ["de", "en"])]) == ["EU"])
    }

    @Test func hintsDefaultToFiftyTerms() {
        let all = (0..<70).map { term("Term\($0)x") }
        #expect(selector.hints(from: VocabularySnapshot(entries: all), for: .nemotron, now: Self.now).count == 50)
    }
}
