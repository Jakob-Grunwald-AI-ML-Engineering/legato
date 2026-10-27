import Foundation
import Testing
@testable import LegatoVocabulary

@Suite("WordPairStore")
struct WordPairStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-pairstore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("wordpairs.json")
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func observePersistsAtomicallyAndReadsBackSynchronously() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = WordPairStore(fileURL: url, languages: ["de"])
        try await store.observe(text: "ich liebe Berlin", now: t0)
        let model = try #require(WordPairModel.read(from: url))
        #expect(model.languages == ["de"])
        #expect(model.predict(after: ["ich"], now: t0) == ["liebe"])
        let reopened = WordPairStore(fileURL: url)
        try await reopened.observe(text: "ich laufe", now: t0)
        #expect(try #require(WordPairModel.read(from: url)).predict(after: ["ich"], now: t0).sorted() == ["laufe", "liebe"])
    }

    @Test func rebuildReplacesEverythingLearnedBefore() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = WordPairStore(fileURL: url)
        try await store.observe(text: "alt gelernt", now: t0)
        try await store.rebuild(from: ["ich liebe Berlin", "ich laufe schnell"], now: t0)
        let model = await store.model()
        #expect(model.predict(after: ["alt"], now: t0) == [])
        #expect(model.predict(after: ["ich"], now: t0).sorted() == ["laufe", "liebe"])
        #expect(try #require(WordPairModel.read(from: url)) == model)
    }

    @Test func rebuildKeepsEachEntrysOwnDateSoOldDictationsStayOld() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = WordPairStore(fileURL: url)
        let longAgo = t0.addingTimeInterval(-5 * 365 * 86_400)
        try await store.rebuild(
            entries: [(text: "ich liebe Berlin", date: longAgo), (text: "ich liebe Berlin", date: longAgo),
                      (text: "ich liebe Berlin", date: longAgo), (text: "ich laufe schnell", date: t0)],
            now: t0)
        let model = await store.model()
        // Three old sightings have decayed to nothing; the one recent sighting wins.
        #expect(model.predict(after: ["ich"], now: t0) == ["laufe"])
    }

    @Test func rebuildFromNothingEmptiesTheModel() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = WordPairStore(fileURL: url)
        try await store.observe(text: "ich liebe", now: t0)
        try await store.rebuild(from: [], now: t0)
        #expect(await store.model().previousWordCount == 0)
    }

    @Test func wipeRemovesTheFileAndTheMemory() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = WordPairStore(fileURL: url)
        try await store.observe(text: "ich liebe", now: t0)
        try await store.wipe()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(WordPairModel.read(from: url) == nil)
        #expect(await store.model().previousWordCount == 0)
        try await store.wipe()
    }

    @Test func concurrentObservesAreAllKept() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = WordPairStore(fileURL: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 { group.addTask { try await store.observe(text: "ich \(uniqueWord(i))", now: t0) } }
            try await group.waitForAll()
        }
        #expect(await store.model().predict(after: ["ich"], limit: 20, now: t0).count == WordPairModel.maxNext)
        #expect(await store.model().previousWordCount == 1)
    }
}
