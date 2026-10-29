import Foundation
import Testing
@testable import LegatoVocabulary

private struct TypingSpellChecker: SpellChecking {
    var known: [String: Set<String>] = [:]
    var guesses: [String: [String]] = [:]
    func isKnown(_ word: String, language: String) async -> Bool { known[word, default: []].contains(language) }
    func guesses(for word: String, language: String) async -> [String] { guesses[language, default: []] }
}

private struct TypingCompleter: WordCompleting {
    let words: [String]
    func completions(prefix: String, languages: [String]) async -> [String] { words }
}

@Suite("Typing suggestions")
struct TypingSuggestionsTests {
    @Test func unknownPrefixOffersTappableNonprefixCorrection() async {
        let candidates = await WordSuggester.candidates(
            prefix: "teh", previous: [], snapshot: nil, pairs: nil, completer: nil,
            checker: TypingSpellChecker(guesses: ["en": ["the"]]), languages: ["en"])
        #expect(candidates.map(\.text) == ["the"])
        #expect(candidates.first?.kind == .correction)
    }

    @Test func aKnownWordInAnyConfiguredLanguageOnlyOffersCompletions() async {
        let candidates = await WordSuggester.candidates(
            prefix: "Haus", previous: [], snapshot: nil, pairs: nil, completer: TypingCompleter(words: ["Haustür"]),
            checker: TypingSpellChecker(known: ["Haus": ["de"]], guesses: ["en": ["House"]]), languages: ["en", "de"])
        #expect(candidates.map(\.text) == ["Haustür"])
        #expect(candidates.map(\.kind) == [.completion])
    }

    @Test func activePersonalVocabularyIsNotFlaggedAsMisspelled() async {
        let snapshot = VocabularySnapshot(entries: [VocabularyEntry(text: "Legato", lastSeen: .distantPast, pinned: true)])
        let candidates = await WordSuggester.candidates(
            prefix: "legato", previous: [], snapshot: snapshot, pairs: nil, completer: nil,
            checker: TypingSpellChecker(guesses: ["en": ["legate"]]), languages: ["en"])
        #expect(candidates == [])
    }

    @Test func correctionsPreserveSuppressionDeduplicationAndCompletionSlots() async {
        let snapshot = VocabularySnapshot(entries: [
            VocabularyEntry(text: "Spam", lastSeen: .distantPast, blocked: true),
            VocabularyEntry(text: "Hello", lastSeen: .distantPast, aliases: ["Helo"]),
        ])
        let candidates = await WordSuggester.candidates(
            prefix: "teh", previous: [], snapshot: snapshot, pairs: nil,
            completer: TypingCompleter(words: ["tehran", "the"]),
            checker: TypingSpellChecker(guesses: ["en": [" ", "SPAM", "Helo", "teh", "the", "THE", "ten"]]),
            languages: ["en"])
        #expect(candidates.map(\.text) == ["the", "tehran", "ten"])
        #expect(candidates.map(\.kind) == [.correction, .completion, .correction])
    }

    @Test(arguments: ["", "   "])
    func emptyPrefixOffersNothing(prefix: String) async {
        let candidates = await WordSuggester.candidates(
            prefix: prefix, previous: [], snapshot: nil, pairs: nil, completer: TypingCompleter(words: ["hello"]),
            checker: TypingSpellChecker(guesses: ["en": ["the"]]), languages: ["en"])
        #expect(candidates == [])
    }

    @Test func languagesShareTheCorrectionSlots() async {
        let candidates = await WordSuggester.candidates(
            prefix: "udn", previous: [], snapshot: nil, pairs: nil, completer: nil,
            checker: TypingSpellChecker(guesses: ["de": ["und", "den"], "en": ["urn", "undo"]]), languages: ["de", "en"])
        #expect(candidates.map(\.text) == ["und", "urn", "den"])
        #expect(candidates.allSatisfy { $0.kind == .correction })
    }
}
