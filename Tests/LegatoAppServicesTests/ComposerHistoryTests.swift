import Foundation
import Testing
import LegatoCore
import LegatoComposerDoc
@testable import LegatoAppServices

private actor FailableComposerHistory: HistoryStore {
    enum Failure: Error { case unavailable }
    var fails = false
    var entries: [DictationEntry] = []
    func setFailure(_ value: Bool) { fails = value }
    func append(_ entry: DictationEntry) throws {
        if fails { throw Failure.unavailable }
        entries.append(entry)
    }
    func upsert(_ entry: DictationEntry) throws {
        if fails { throw Failure.unavailable }
        entries.removeAll { $0.id == entry.id }; entries.append(entry)
    }
    func recent(limit: Int) -> [DictationEntry] { Array(entries.reversed().prefix(limit)) }
    func delete(id: UUID) { entries.removeAll { $0.id == id } }
}

@MainActor struct ComposerHistoryTests {
    @Test func editsUpdateOneDurableEntryAndClearingNeverOverwritesItWithEmpty() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLHistoryStore(fileURL: url)
        let session = ComposerSession(history: store)
        try await session.seedDebugDraft("Keep ths sentence")
        let first = try #require(try await store.recent(limit: 10).first)
        let line = try #require(session.snapshot.lines.first)
        let ops = [DocOp.replaceInLine(lineID: line.id, old: "ths", new: "this")]
        try await session.applyDebugDocumentEdits(String(decoding: JSONEncoder().encode(ops), as: UTF8.self))
        await session.stop()
        #expect(await session.flushHistory())
        let updated = try await store.recent(limit: 10)
        #expect(updated.count == 1)
        #expect(updated[0].id == first.id && updated[0].date == first.date)
        #expect(updated[0].text == "Keep this sentence")
        await session.cancel()
        #expect(session.renderedText.isEmpty)
        let reopened = JSONLHistoryStore(fileURL: url)
        #expect(try await reopened.recent(limit: 10).map(\.text) == ["Keep this sentence"])
        try await session.seedDebugDraft("Another composition")
        #expect(try await store.recent(limit: 10).count == 2)
    }

    @Test func deliveryIsCheckpointedBeforeAcknowledgementAndNextCompositionHasAnotherID() async throws {
        let store = FailableComposerHistory()
        let session = ComposerSession(history: store)
        try await session.seedDebugDraft("Deliver this draft")
        #expect(try await session.prepareForInsertion() == "Deliver this draft")
        let first = try #require(await store.recent(limit: 10).first)
        await session.insert()
        #expect(session.status == "idle")
        #expect(await store.recent(limit: 10).first == first)
        try await session.seedDebugDraft("New topic text")
        await session.startNewTopic()
        let saved = await store.recent(limit: 10)
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.id)).count == 2)
        #expect(saved.map(\.text) == ["New topic text", "Deliver this draft"])
    }

    @Test func unavailableHistoryBlocksDeliveryAndClearButAllowsExplicitRetry() async throws {
        let store = FailableComposerHistory()
        await store.setFailure(true)
        let session = ComposerSession(history: store)
        try await session.seedDebugDraft("Never lose this draft")
        await #expect(throws: (any Error).self) { try await session.prepareForInsertion() }
        await session.cancel()
        #expect(session.renderedText == "Never lose this draft")
        #expect(session.error?.contains("History") == true)
        await store.setFailure(false)
        #expect(try await session.prepareForInsertion() == "Never lose this draft")
        #expect(session.error == nil)
        await session.cancel()
        #expect(session.renderedText.isEmpty)
        #expect(await store.recent(limit: 10).map(\.text) == ["Never lose this draft"])
    }
}
