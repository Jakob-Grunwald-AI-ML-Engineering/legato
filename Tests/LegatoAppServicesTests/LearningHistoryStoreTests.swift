import Foundation
import LegatoCore
import LegatoVocabulary
import Synchronization
import Testing
@testable import LegatoAppServices

/// An in-memory history that can be told to fail appends.
private final class MemoryHistory: HistoryStore {
    struct Failure: Error {}
    private let state = Mutex<[DictationEntry]>([])
    let failAppends: Bool
    let failDeletes: Bool
    init(failAppends: Bool = false, failDeletes: Bool = false) {
        self.failAppends = failAppends
        self.failDeletes = failDeletes
    }
    var all: [DictationEntry] { state.withLock { $0 } }
    func append(_ entry: DictationEntry) async throws {
        if failAppends { throw Failure() }
        state.withLock { $0.append(entry) }
    }
    func recent(limit: Int) async throws -> [DictationEntry] { Array(all.reversed().prefix(limit)) }
    func delete(id: UUID) async throws {
        if failDeletes { throw Failure() }
        state.withLock { $0.removeAll { $0.id == id } }
    }
}

private func entry(_ text: String, raw: String? = nil, locale: String = "en-US") -> DictationEntry {
    DictationEntry(
        date: Date(timeIntervalSince1970: 1_700_000_000), text: text, rawText: raw, localeIdentifier: locale,
        engineID: "test", duration: 1)
}

private let grunwald = [EntitySpan(text: "Grunwald", kind: .person)]

@Suite struct LearningHistoryStoreTests {
    @Test func forwardsAppendRecentAndDelete() async throws {
        let rig = VocabularyRig(); defer { rig.cleanUp() }
        let base = MemoryHistory()
        let store = LearningHistoryStore(base, vocabulary: rig.service)
        let first = entry("one"), second = entry("two")
        try await store.append(first)
        try await store.append(second)
        #expect(base.all == [first, second])
        #expect(try await store.recent(limit: 1) == [second])
        try await store.delete(id: first.id)
        #expect(base.all == [second])
        await rig.service.waitForLearning()
    }

    @Test func observesRawTextWhenPresentWithTheEntryID() async throws {
        let rig = VocabularyRig(spans: grunwald); defer { rig.cleanUp() }
        let store = LearningHistoryStore(MemoryHistory(), vocabulary: rig.service)
        // Generated wording must not count as a spoken sighting of Grunwald.
        let first = entry("we met Grunwald", raw: "we met grün wald")
        try await store.append(first)
        try await store.append(first)  // the same id again counts once
        await rig.service.waitForLearning()
        #expect(try await rig.entries().isEmpty)
        try await store.append(entry("ask Grunwald today"))
        await rig.service.waitForLearning()
        #expect(try await rig.entries().isEmpty)
        try await store.append(entry("we met Grunwald again"))
        await rig.service.waitForLearning()
        #expect(try await rig.entries().map(\.text) == ["Grunwald"])
    }

    @Test func aFailedAppendObservesNothing() async throws {
        let rig = VocabularyRig(spans: grunwald); defer { rig.cleanUp() }
        let store = LearningHistoryStore(MemoryHistory(failAppends: true), vocabulary: rig.service)
        for _ in 0..<2 {
            await #expect(throws: MemoryHistory.Failure.self) { try await store.append(entry("we met Grunwald")) }
        }
        #expect(rig.service.pendingLearning == 0)
        await rig.service.waitForLearning()
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.pendingTerms.isEmpty)
    }

    @Test func aSlowLearnerNeverDelaysTheAppend() async throws {
        let gate = LearnerGate()
        let rig = VocabularyRig(spellChecker: GatedSpellChecker(gate: gate)); defer { rig.cleanUp() }
        let base = MemoryHistory()
        let store = LearningHistoryStore(base, vocabulary: rig.service)
        try await store.append(entry("Grunwald"))
        // The append returned, the entry is stored, and the learner is still held inside the spell checker.
        #expect(base.all.count == 1)
        #expect(rig.service.pendingLearning == 1)
        await gate.release()
        await rig.service.waitForLearning()
        #expect(rig.service.pendingLearning == 0)
    }

    // MARK: deleting a dictation un-teaches it

    @Test func deletingADictationForgetsWhatItTaught() async throws {
        let rig = VocabularyRig(spans: grunwald); defer { rig.cleanUp() }
        let store = LearningHistoryStore(MemoryHistory(), vocabulary: rig.service)
        let first = entry("we met Grunwald")
        try await store.append(first)
        await rig.service.waitForLearning()
        #expect(try await rig.service.store.snapshot().pendingTerms.map(\.text) == ["Grunwald"])
        try await store.delete(id: first.id)
        await rig.service.waitForLearning()
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.pendingTerms.isEmpty)
        #expect(snapshot.entries.isEmpty)
    }

    @Test func aDeleteRightAfterAnAppendLeavesNoTraceEvenWhileTheLearnerIsStillBusy() async throws {
        let gate = LearnerGate()
        let rig = VocabularyRig(spellChecker: GatedSpellChecker(gate: gate)); defer { rig.cleanUp() }
        let store = LearningHistoryStore(MemoryHistory(), vocabulary: rig.service)
        let doomed = entry("Grunwald")
        try await store.append(doomed)  // the learner is now held inside the spell checker
        try await store.delete(id: doomed.id)  // the Mac's cancel chord: append, then delete at once
        await gate.release()
        await rig.service.waitForLearning()
        let snapshot = try await rig.service.store.snapshot()
        #expect(snapshot.pendingTerms.isEmpty)
        #expect(snapshot.entries.isEmpty)
    }

    @Test func aFailedDeleteForgetsNothing() async throws {
        let rig = VocabularyRig(spans: grunwald); defer { rig.cleanUp() }
        let store = LearningHistoryStore(MemoryHistory(failDeletes: true), vocabulary: rig.service)
        let kept = entry("we met Grunwald")
        try await store.append(kept)
        await rig.service.waitForLearning()
        await #expect(throws: MemoryHistory.Failure.self) { try await store.delete(id: kept.id) }
        await rig.service.waitForLearning()
        #expect(try await rig.service.store.snapshot().pendingTerms.map(\.text) == ["Grunwald"])
    }
}
