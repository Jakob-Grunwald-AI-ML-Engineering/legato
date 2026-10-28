import Foundation
import LegatoCore
import LegatoVocabulary
import Synchronization
import Testing
@testable import LegatoAppServices

/// An in-memory history, oldest first, newest returned first like the real stores.
private final class PairsHistory: HistoryStore {
    private let state = Mutex<[DictationEntry]>([])
    func append(_ entry: DictationEntry) async throws { state.withLock { $0.append(entry) } }
    func recent(limit: Int) async throws -> [DictationEntry] { Array(state.withLock { $0 }.reversed().prefix(limit)) }
    func delete(id: UUID) async throws { state.withLock { $0.removeAll { $0.id == id } } }
}

private func dictation(_ text: String) -> DictationEntry {
    DictationEntry(
        date: Date(timeIntervalSince1970: 1_700_000_000), text: text, rawText: nil, localeIdentifier: "en-US",
        engineID: "test", duration: 1)
}

private let t = Date(timeIntervalSince1970: 1_700_000_000)

private func predictions(_ url: URL, after word: String) -> [String] {
    WordPairModel.read(from: url)?.predict(after: [word], now: t) ?? []
}

@Suite struct VocabularyPairsTests {
    @Test func generatedHeadingsNeverTeachPairsDuringAppendOrRebuild() async throws {
        let rig = VocabularyRig(withPairs: true); defer { rig.cleanUp() }
        let base = PairsHistory()
        let history = LearningHistoryStore(base, vocabulary: rig.service)
        let kept = DictationEntry(date: t, text: "project overview", rawText: "see you tomorrow", localeIdentifier: "en-US", engineID: "test", duration: 1)
        let removed = dictation("good morning")
        try await history.append(kept)
        try await history.append(removed)
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "project").isEmpty)
        #expect(predictions(rig.pairsURL, after: "see") == ["you"])
        try await history.delete(id: removed.id)
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "project").isEmpty)
        #expect(predictions(rig.pairsURL, after: "see") == ["you"])
    }

    @Test func aDictationTeachesWordPairs() async throws {
        let rig = VocabularyRig(withPairs: true); defer { rig.cleanUp() }
        rig.service.learnFromDictation(text: "see you tomorrow", locale: Locale(identifier: "en-US"), id: UUID())
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "see") == ["you"])
    }

    @Test func withoutAPairFileNothingIsWritten() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        rig.service.learnFromDictation(text: "see you tomorrow", locale: Locale(identifier: "en-US"), id: UUID())
        await rig.service.waitForLearning()
        #expect(rig.service.pairs == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.pairsURL.path))
    }

    @Test func theBackfillBuildsFromHistoryOnceAndStopsAtTheMarker() async throws {
        let rig = VocabularyRig(withPairs: true); defer { rig.cleanUp() }
        let history = PairsHistory()
        try await history.append(dictation("see you tomorrow"))
        rig.service.backfillPairsIfNeeded(history: history)
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "see") == ["you"])

        // Marker set: a later history entry is not picked up by a second backfill.
        try await history.append(dictation("good morning everyone"))
        rig.service.backfillPairsIfNeeded(history: history)
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "good").isEmpty)
    }

    @Test func forgettingRebuildsWithoutTheForgottenText() async throws {
        let rig = VocabularyRig(withPairs: true); defer { rig.cleanUp() }
        let history = LearningHistoryStore(PairsHistory(), vocabulary: rig.service)
        let keep = dictation("see you tomorrow")
        let drop = dictation("good morning everyone")
        try await history.append(keep)
        try await history.append(drop)
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "good") == ["morning"])

        try await history.delete(id: drop.id)
        await rig.service.waitForLearning()
        #expect(predictions(rig.pairsURL, after: "good").isEmpty)
        #expect(predictions(rig.pairsURL, after: "see") == ["you"])
    }

    @Test func rebuildingKeepsTheAgeOfEachDictation() async throws {
        let rig = VocabularyRig(withPairs: true); defer { rig.cleanUp() }
        let history = PairsHistory()
        let old = Date(timeIntervalSince1970: 1_700_000_000 - 3 * 365 * 86_400)
        for _ in 0..<3 {
            try await history.append(DictationEntry(date: old, text: "see old news", rawText: nil, localeIdentifier: "en-US", engineID: "test", duration: 1))
        }
        try await history.append(dictation("see new things"))
        rig.service.backfillPairsIfNeeded(history: history)
        await rig.service.waitForLearning()
        // Observed "now", three old sightings would outweigh one new one.
        #expect(predictions(rig.pairsURL, after: "see") == ["new"])
    }

    @Test func wipingRemovesBothPairFiles() async throws {
        let rig = VocabularyRig(withPairs: true); defer { rig.cleanUp() }
        rig.service.learnFromDictation(text: "see you tomorrow", locale: Locale(identifier: "en-US"), id: UUID())
        await rig.service.waitForLearning()
        try Data("{}".utf8).write(to: rig.typedPairsURL)
        #expect(FileManager.default.fileExists(atPath: rig.pairsURL.path))

        rig.service.wipeWordPairs()
        await rig.service.waitForLearning()
        #expect(!FileManager.default.fileExists(atPath: rig.pairsURL.path))
        #expect(!FileManager.default.fileExists(atPath: rig.typedPairsURL.path))
    }

    @Test func aRecordedChoiceReachesTheVocabulary() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        rig.service.recordChoice(original: "kloud", chosen: "Claude", fromVocabulary: false)
        await rig.service.waitForLearning()
        let entry = try #require(try await rig.service.store.snapshot().entry(forText: "Claude"))
        #expect(entry.aliases == ["kloud"])
    }
}
