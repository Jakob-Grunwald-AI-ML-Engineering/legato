import Foundation
import LegatoCore
import LegatoEngines
import LegatoModels
import LegatoPostProcessing
import LegatoVocabulary
import Synchronization
import Testing
@testable import LegatoAppServices

/// A dictionary fake: a word is known in a language when its lowercase form is in that language's set.
struct FakeSpellChecker: SpellChecking {
    var known: [String: Set<String>] = [:]
    func isKnown(_ word: String, language: String) async -> Bool { known[language]?.contains(word.lowercased()) ?? false }
    func guesses(for word: String, language: String) async -> [String] { [] }
}

/// A tagger fake: returns the configured names that occur in the text.
struct FakeTagger: EntityTagging {
    var spans: [EntitySpan] = []
    func entities(in text: String, language: String) -> [EntitySpan] { spans.filter { text.contains($0.text) } }
}

/// A spell checker that stays inside `isKnown` until released, to hold a learner mid-flight.
actor LearnerGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pass() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

struct GatedSpellChecker: SpellChecking {
    let gate: LearnerGate
    func isKnown(_ word: String, language: String) async -> Bool {
        await gate.pass()
        return false
    }
    func guesses(for word: String, language: String) async -> [String] { [] }
}

/// A language list a test can change while a service reads it.
final class LanguageBox: Sendable {
    private let value: Mutex<[String]>
    init(_ languages: [String]) { value = Mutex(languages) }
    var current: [String] { value.withLock { $0 } }
    func set(_ languages: [String]) { value.withLock { $0 = languages } }
}

/// A service over a temp file; `known` words are common in both languages.
struct VocabularyRig {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "legato-vocab-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "vocabulary.json")
    let service: VocabularyService
    /// Where the dictated word pairs live when the rig was built `withPairs`; the keyboard's file sits beside it.
    var pairsURL: URL { url.deletingLastPathComponent().appending(path: "wordpairs-dictated.json") }
    var typedPairsURL: URL { url.deletingLastPathComponent().appending(path: VocabularyService.typedPairsFileName) }

    init(
        spellChecker: (any SpellChecking)? = nil, spans: [EntitySpan] = [],
        known: Set<String> = ["we", "met", "with", "today", "ask", "about", "it", "this", "is", "at", "the"],
        languages: @escaping @Sendable () -> [String] = { ["de", "en"] }, withPairs: Bool = false
    ) {
        service = VocabularyService(
            fileURL: url, languages: languages,
            spellChecker: spellChecker ?? FakeSpellChecker(known: ["de": known, "en": known]),
            tagger: FakeTagger(spans: spans), now: { Date(timeIntervalSince1970: 1_700_000_000) },
            pairsFileURL: withPairs ? url.deletingLastPathComponent().appending(path: "wordpairs-dictated.json") : nil)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func entries() async throws -> [VocabularyEntry] { try await service.store.snapshot().entries }
}

@Suite struct VocabularyServiceTests {
    @Test func hintsMapTheSinkAndKeepSpellingsButNeverAliases() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        try await rig.service.store.add(text: "Grunwald", aliases: ["gruenwald-ish"], spellings: ["Grünwald"])
        let hints = await rig.service.hints(for: .nemotron, limit: 50)
        #expect(hints == [VocabularyHint(text: "Grunwald", spellings: ["Grünwald"])])
    }

    @Test func hintsApplyTheSinkFloorAndTheLimit() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        try await rig.service.store.add(text: "KI")
        try await rig.service.store.add(text: "Legato")
        try await rig.service.store.add(text: "Grunwald")
        #expect(await rig.service.hints(for: .nemotron, limit: 50).map(\.text).contains("KI") == false)
        #expect(await rig.service.hints(for: .appleSpeech, limit: 50).map(\.text).contains("KI"))
        #expect(await rig.service.hints(for: .cleanup, limit: 50).map(\.text).contains("KI"))
        #expect(await rig.service.hints(for: .appleSpeech, limit: 2).count == 2)
    }

    @Test func cleanupTermsAreThePinnedOnesPlusTheHitsInTheText() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let pinned = try await rig.service.store.add(text: "Legato")
        try await rig.service.store.pin(id: pinned.id)
        try await rig.service.store.add(text: "Grunwald")
        try await rig.service.store.add(text: "Kubernetes")
        let terms = await rig.service.cleanupTerms(for: "ich treffe Herrn Grunwald heute")
        #expect(terms == ["Legato", "Grunwald"])
    }

    @Test func aDictationIsLearnedInTheBackgroundOncePerID() async throws {
        let rig = VocabularyRig(spans: [EntitySpan(text: "Grunwald", kind: .person)]); defer { rig.cleanUp() }
        let first = UUID()
        rig.service.learnFromDictation(text: "we met Grunwald", locale: Locale(identifier: "en-US"), id: first)
        rig.service.learnFromDictation(text: "we met Grunwald", locale: Locale(identifier: "en-US"), id: first)
        await rig.service.waitForLearning()
        #expect(try await rig.entries().isEmpty)
        rig.service.learnFromDictation(text: "ask Grunwald today", locale: Locale(identifier: "en-US"), id: UUID())
        await rig.service.waitForLearning()
        let entries = try await rig.entries()
        #expect(entries.map(\.text) == ["Grunwald"])
        #expect(entries.first?.kind == .person)
    }

    @Test func aVerbatimFixRepeatedInTwoRunsTeachesAnAlias() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let locale = Locale(identifier: "en-US")
        for _ in 0..<2 {
            rig.service.learnFromCleanup(
                raw: "ask kloud about it", cleaned: "ask Claude about it", style: .verbatim, runID: UUID(), locale: locale)
        }
        await rig.service.waitForLearning()
        let claude = try #require(try await rig.entries().first { $0.text == "Claude" })
        #expect(claude.aliases.contains("kloud"))
        #expect(claude.correctionTarget)
    }

    @Test func aMessageStyleRewriteTeachesNothing() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        for _ in 0..<3 {
            rig.service.learnFromCleanup(
                raw: "ask kloud about it", cleaned: "ask Claude about it", style: .message, runID: UUID(),
                locale: Locale(identifier: "en-US"))
        }
        await rig.service.waitForLearning()
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.pendingFixes.isEmpty)
    }

    @Test func theLanguagesComeFromTheEngineSettingsElseTheSystem() {
        let settings = EngineSettings(defaults: UserDefaults(suiteName: "legato-vocab-langs-\(UUID().uuidString)")!)
        #expect(VocabularyService.configuredLanguages(settings, system: ["de-DE", "en-US", "de-AT"]) == ["de", "en"])
        #expect(VocabularyService.configuredLanguages(settings, system: []) == ["en"])
        settings.preferredLocales = [Locale(identifier: "fr-FR"), Locale(identifier: "de_DE")]
        #expect(VocabularyService.configuredLanguages(settings, system: ["en-US"]) == ["fr", "de"])
    }

    @Test func theLanguagesAreReadOnEveryCallNotFrozenAtInit() async throws {
        let languages = LanguageBox(["en"])
        let speller = FakeSpellChecker(known: ["de": ["grunwald"], "en": ["we", "met", "today"]])
        let rig = VocabularyRig(
            spellChecker: speller, spans: [EntitySpan(text: "Grunwald", kind: .person)], languages: { languages.current })
        defer { rig.cleanUp() }
        let locale = Locale(identifier: "en-US")
        rig.service.learnFromDictation(text: "we met Grunwald today", locale: locale, id: UUID())
        await rig.service.waitForLearning()
        languages.set(["de", "en"])
        rig.service.learnFromDictation(text: "we met Grunwald today", locale: locale, id: UUID())
        await rig.service.waitForLearning()
        // Promoted by the second call, which checked the new set: German knows the name.
        #expect(try await rig.entries().first?.knownIn == ["de"])
    }

    @Test func hintsFollowTheCurrentLanguages() async throws {
        let languages = LanguageBox(["en"])
        let rig = VocabularyRig(languages: { languages.current })
        defer { rig.cleanUp() }
        try await rig.service.store.update { snap in
            snap.entries.append(VocabularyEntry(text: "Fenster", source: .history, lastSeen: Date(), knownIn: ["de"]))
        }
        #expect(await rig.service.hints(for: .appleSpeech, limit: 50).map(\.text) == ["Fenster"])  // unknown in English
        languages.set(["de", "en"])
        #expect(await rig.service.hints(for: .appleSpeech, limit: 50).isEmpty)  // German knows it
    }

    // MARK: forgetting

    private func learn(_ rig: VocabularyRig, _ text: String, id: UUID, times n: Int = 1) async {
        for _ in 0..<n {
            rig.service.learnFromDictation(text: text, locale: Locale(identifier: "en-US"), id: id)
        }
        await rig.service.waitForLearning()
    }

    @Test func forgettingADictationDropsItFromThePendingTerms() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let kept = UUID(), gone = UUID()
        await learn(rig, "we met Zorbax today", id: kept)
        await learn(rig, "we met Zorbax today", id: gone)  // two of the three sightings an unknown word needs
        #expect(try await rig.service.store.snapshot().pendingTerms.first?.ids == [kept, gone])
        rig.service.forget(dictationID: gone)
        await rig.service.waitForLearning()
        let pending = try #require(try await rig.service.store.snapshot().pendingTerms.first)
        #expect(pending.ids == [kept])
        #expect(pending.score == 1)
    }

    @Test func aPendingTermWithNoIDsLeftIsDropped() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let id = UUID()
        await learn(rig, "we met Zorbax today", id: id)
        rig.service.forget(dictationID: id)
        await rig.service.waitForLearning()
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.pendingTerms.isEmpty)
        #expect(snapshot.entries.isEmpty)
    }

    @Test func forgettingTakesTheIDOutOfAnEntryAndKeepsAnEntryOtherDictationsStillSupport() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let ids = [UUID(), UUID(), UUID()]
        for id in ids { await learn(rig, "we met Zorbax today", id: id) }
        #expect(try await rig.entries().first?.recentIDs == ids)
        rig.service.forget(dictationID: ids[2])
        await rig.service.waitForLearning()
        let entry = try #require(try await rig.entries().first)
        #expect(entry.recentIDs == [ids[0], ids[1]])
        #expect(entry.score == 2)
    }

    @Test func aLearnedEntryWhoseOnlySightingWasTheDictationIsRemoved() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let id = UUID()
        try await rig.service.store.learn(text: "Zorbax", source: .history, id: id)
        try await rig.service.store.learn(text: "Quillon", source: .history, id: UUID())
        rig.service.forget(dictationID: id)
        await rig.service.waitForLearning()
        #expect(try await rig.entries().map(\.text) == ["Quillon"])
    }

    @Test func aManualOrPinnedEntryIsNeverRemovedByForgetting() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let id = UUID()
        let manual = try await rig.service.store.add(text: "Legato")
        let pinned = try await rig.service.store.learn(text: "Zorbax", source: .history, id: id)
        try await rig.service.store.update { snap in
            snap.entries[0].recentIDs = [id]
            snap.entries[0].score = 2
        }
        try await rig.service.store.pin(id: try #require(pinned).id)
        rig.service.forget(dictationID: id)
        await rig.service.waitForLearning()
        let entries = try await rig.entries()
        #expect(entries.map(\.text) == ["Legato", "Zorbax"])
        #expect(entries.allSatisfy { !$0.recentIDs.contains(id) })
        #expect(manual.text == "Legato")
    }

    @Test func forgettingDropsTheIDFromThePendingFixesToo() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let id = UUID(), other = UUID(), t = Date()
        try await rig.service.store.update { snap in
            snap.pendingFixes = [
                PendingFix(raw: "kloud", target: "Claude", ids: [id, other], score: 2, lastSeen: t),
                PendingFix(raw: "klaud", target: "Claude", ids: [id], score: 1, lastSeen: t),
            ]
        }
        rig.service.forget(dictationID: id)
        await rig.service.waitForLearning()
        let fixes = try await rig.service.store.snapshot().pendingFixes
        #expect(fixes.map(\.raw) == ["kloud"])
        #expect(fixes.first?.ids == [other])
    }

    @Test func aForgetQueuedBehindASlowLearnerStillWins() async throws {
        let gate = LearnerGate()
        let rig = VocabularyRig(spellChecker: GatedSpellChecker(gate: gate)); defer { rig.cleanUp() }
        let id = UUID()
        rig.service.learnFromDictation(text: "Zorbax", locale: Locale(identifier: "en"), id: id)
        rig.service.forget(dictationID: id)  // arrives while the learner is still inside the spell checker
        await gate.release()
        await rig.service.waitForLearning()
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.pendingTerms.isEmpty)
        #expect(snapshot.entries.isEmpty)
    }

    @Test func learningTasksRunOneAfterAnother() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { rig.service.learnFromDictation(text: "we met Zorbax today", locale: Locale(identifier: "en"), id: id) }
        await rig.service.waitForLearning()
        // Five concurrent read-modify-write passes would lose or double count sightings; in order they promote at three.
        let entry = try #require(try await rig.entries().first)
        #expect(entry.recentIDs == ids)
    }

    @Test func theStylesMapOntoTheLearningStyles() {
        #expect(VocabularyService.learningStyle(.verbatim) == .verbatim)
        #expect(VocabularyService.learningStyle(.message) == .message)
        #expect(VocabularyService.learningStyle(.markdown) == .message)
    }

    @Test func learningReturnsAtOnceWhileTheLearnerIsStillBusy() async throws {
        let gate = LearnerGate()
        let rig = VocabularyRig(spellChecker: GatedSpellChecker(gate: gate)); defer { rig.cleanUp() }
        rig.service.learnFromDictation(text: "Grunwald", locale: Locale(identifier: "en"), id: UUID())
        #expect(rig.service.pendingLearning == 1)
        await gate.release()
        await rig.service.waitForLearning()
        #expect(rig.service.pendingLearning == 0)
    }

    @Test func waitingWithNothingInFlightReturnsImmediately() async {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        await rig.service.waitForLearning()
    }
}

// MARK: cleanup processor

/// Answers every prompt with a fixed cleaned sentence and keeps the prompts it saw.
private final class ReplyingBackend: LLMBackend {
    let id = "replying"
    let maxPromptCharacters: Int? = nil
    private let seen = Mutex<[String]>([])
    let reply: String
    init(reply: String) { self.reply = reply }
    var prompts: [String] { seen.withLock { $0 } }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        seen.withLock { $0.append(prompt) }
        return "<text>\(reply)</text>"
    }
}

@Suite struct CleanupProcessorVocabularyTests {
    private func processor(
        backend: ReplyingBackend, vocabulary: VocabularyService?, style: CleanupStyle = .verbatim
    ) -> CleanupProcessor {
        let defaults = UserDefaults(suiteName: "legato-vocab-tests-\(UUID().uuidString)")!
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.enabled = true
        settings.style = style
        let manager = ModelManager(
            root: FileManager.default.temporaryDirectory.appending(path: "legato-vocab-\(UUID().uuidString)"),
            catalog: [], installers: [:], selection: SelectionStore(defaults: defaults))
        return CleanupProcessor(
            registry: CleanupRegistry(models: manager, foundationModels: backend), settings: settings,
            vocabulary: vocabulary, report: { _ in })
    }

    @Test func theTermsInTheTextReachTheModel() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        try await rig.service.store.add(text: "Grunwald")
        try await rig.service.store.add(text: "Kubernetes")
        let backend = ReplyingBackend(reply: "ask Grunwald about it")
        _ = try await processor(backend: backend, vocabulary: rig.service)
            .process("ask grunwald about it", locale: Locale(identifier: "en-US"))
        let prompt = try #require(backend.prompts.first)
        #expect(prompt.contains("<terms>Grunwald</terms>"))
    }

    @Test func withoutAServiceThePromptHasNoTerms() async throws {
        let backend = ReplyingBackend(reply: "ask Grunwald about it")
        _ = try await processor(backend: backend, vocabulary: nil)
            .process("ask grunwald about it", locale: Locale(identifier: "en-US"))
        #expect(backend.prompts.first?.contains("<terms>") == false)
    }

    @Test func aRunLearnsRawVersusCleanedAcrossTwoRuns() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let backend = ReplyingBackend(reply: "ask Claude about it")
        let processor = processor(backend: backend, vocabulary: rig.service)
        for _ in 0..<2 {
            _ = try await processor.process("ask kloud about it", locale: Locale(identifier: "en-US"))
        }
        await rig.service.waitForLearning()
        let claude = try #require(try await rig.entries().first { $0.text == "Claude" })
        #expect(claude.aliases == ["kloud"])
    }

    @Test func aSwapToATermTheModelWasGivenIsNoEvidence() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        try await rig.service.store.add(text: "Claude")
        let backend = ReplyingBackend(reply: "ask Claude about it")
        let processor = processor(backend: backend, vocabulary: rig.service)
        for _ in 0..<3 {
            _ = try await processor.process("ask kloud about it", locale: Locale(identifier: "en-US"))
        }
        await rig.service.waitForLearning()
        #expect(backend.prompts.allSatisfy { $0.contains("<terms>Claude</terms>") })
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.entries.map(\.text) == ["Claude"])
        #expect(snapshot.entries[0].aliases == [])
        #expect(snapshot.entries[0].score == 1)
        #expect(snapshot.pendingFixes.isEmpty)
    }

    @Test(arguments: [CleanupStyle.message, .markdown])
    func aRewriteStyleRunTeachesNothing(style: CleanupStyle) async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let backend = ReplyingBackend(reply: "ask Claude about it")
        let processor = processor(backend: backend, vocabulary: rig.service, style: style)
        for _ in 0..<2 {
            _ = try await processor.process("ask kloud about it", locale: Locale(identifier: "en-US"))
        }
        await rig.service.waitForLearning()
        #expect(try await rig.entries().isEmpty)
    }

    @Test func thePassesOfOneLiveRunCountAsOneRun() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let backend = ReplyingBackend(reply: "ask Claude about it")
        let processor = processor(backend: backend, vocabulary: rig.service)
        let locale = Locale(identifier: "en-US")
        processor.liveRunStarts()
        _ = try await processor.cleanLivePass("ask kloud about it", context: "", locale: locale, atStop: false)
        _ = try await processor.cleanLivePass("ask kloud about it", context: "", locale: locale, atStop: true)
        await rig.service.waitForLearning()
        #expect(try await rig.entries().isEmpty)  // one run: not yet the two distinct runs a fix needs
        processor.liveRunStarts()
        _ = try await processor.cleanLivePass("ask kloud about it", context: "", locale: locale, atStop: true)
        await rig.service.waitForLearning()
        #expect(try await rig.entries().map(\.text) == ["Claude"])
    }
}
