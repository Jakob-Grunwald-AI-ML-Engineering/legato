import Foundation
import Testing
@testable import LegatoVocabulary

@Suite struct VocabularyStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("legato-vocab-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }

    func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: persistence

    @Test func roundTripsThroughANewStoreInstance() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let runID = UUID()
        let entry = try await store.add(text: "Grünwald", kind: .place, aliases: ["Grunwald"], spellings: ["Gruenwald"], now: t0)
        try await store.update(now: t0) { snap in
            snap.entries[0].knownIn = ["en"]
            snap.entries[0].recentIDs = [runID]
            snap.entries[0].correctionTarget = true
            snap.pendingTerms = [PendingTerm(text: "Kubernetes", kind: .term, ids: [runID], score: 2, lastSeen: t0)]
            snap.pendingFixes = [PendingFix(raw: "kloud", target: "Claude", ids: [runID], score: 1, lastSeen: t0)]
        }
        let expected = try await store.snapshot()

        let reloaded = VocabularyStore(fileURL: url)
        let snap = try await reloaded.snapshot()
        #expect(snap == expected)
        #expect(snap.version == 1)
        #expect(snap.entries.map(\.id) == [entry.id])
        #expect(snap.entries[0].aliases == ["Grunwald"])
        #expect(snap.entries[0].spellings == ["Gruenwald"])
        #expect(snap.entries[0].recentIDs == [runID])
        #expect(snap.pendingTerms.map(\.text) == ["Kubernetes"])
        #expect(snap.pendingFixes.map(\.target) == ["Claude"])
        #expect(try VocabularySnapshot.read(from: url) == expected)
    }

    @Test func missingFileLoadsAsEmptySnapshot() async throws {
        let store = VocabularyStore(fileURL: tempURL())
        let snap = try await store.snapshot()
        #expect(snap.entries.isEmpty)
        #expect(snap.version == 1)
    }

    @Test func atomicRewriteLeavesValidJSONAndNoTempFiles() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        for i in 0..<20 { try await store.add(text: "Term\(i)", now: t0) }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
        #expect((json?["entries"] as? [Any])?.count == 20)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["vocabulary.json"])
    }

    @Test func unknownVersionIsRefusedAndTheFileIsLeftUntouched() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version": 2, "entries": [], "future": true}"#.utf8)
        try original.write(to: url)
        let store = VocabularyStore(fileURL: url)

        await #expect(throws: VocabularyStoreError.unsupportedVersion(2)) { try await store.load() }
        await #expect(throws: VocabularyStoreError.unsupportedVersion(2)) { try await store.add(text: "Claude") }
        #expect(throws: VocabularyStoreError.unsupportedVersion(2)) { try VocabularySnapshot.read(from: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func datesAreStoredAsIntegerMilliseconds() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        try await store.add(text: "Claude", now: Date(timeIntervalSince1970: 1_700_000_000.123))
        try await store.update(now: t0) { $0.pendingTerms = [PendingTerm(text: "x", lastSeen: Date(timeIntervalSince1970: 1_700_000_001.5))] }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let entries = json?["entries"] as? [[String: Any]]
        let pending = json?["pendingTerms"] as? [[String: Any]]
        #expect(entries?.first?["lastSeen"] as? Int == 1_700_000_000_123)
        #expect(pending?.first?["lastSeen"] as? Int == 1_700_000_001_500)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("1700000000123.") && !raw.contains("e+"))
    }

    // MARK: manual edits

    @Test func addCreatesAManualEntryAndDeduplicatesByText() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let first = try await store.add(text: "Claude", kind: .organisation, now: t0)
        let again = try await store.add(text: " claude ", now: t0.addingTimeInterval(60))
        #expect(first.source == .manual)
        #expect(first.kind == .organisation)
        #expect(again.id == first.id)
        let snap = try await store.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].lastSeen == t0.addingTimeInterval(60))
    }

    @Test func pinAndUnpin() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let e = try await store.add(text: "Claude", now: t0)
        try await store.pin(id: e.id)
        #expect(try await store.snapshot().entries[0].pinned)
        try await store.unpin(id: e.id)
        #expect(try await !store.snapshot().entries[0].pinned)
    }

    @Test func blockUnpinsAndKeepsATombstone() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let e = try await store.add(text: "Claude", now: t0)
        try await store.pin(id: e.id)
        try await store.block(id: e.id)
        let snap = try await store.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].blocked)
        #expect(!snap.entries[0].pinned)
        #expect(snap.isBlocked("CLAUDE"))
        try await store.unblock(id: e.id)
        #expect(try await !store.snapshot().entries[0].blocked)
    }

    @Test func removeDeletesTheEntry() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let a = try await store.add(text: "Claude", now: t0)
        try await store.add(text: "Kubernetes", now: t0)
        try await store.remove(id: a.id)
        #expect(try await store.snapshot().entries.map(\.text) == ["Kubernetes"])
    }

    @Test func renameChangesTextAndRefusesACollision() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let a = try await store.add(text: "Claud", now: t0)
        try await store.add(text: "Kubernetes", now: t0)
        try await store.rename(id: a.id, to: "Claude")
        #expect(try await store.snapshot().entries.map(\.text) == ["Claude", "Kubernetes"])
        await #expect(throws: VocabularyStoreError.duplicate("kubernetes")) { try await store.rename(id: a.id, to: "kubernetes") }
        #expect(try await store.snapshot().entries.map(\.text) == ["Claude", "Kubernetes"])
    }

    @Test func editingAnUnknownIdThrowsNotFound() async throws {
        let store = VocabularyStore(fileURL: tempURL())
        let missing = UUID()
        await #expect(throws: VocabularyStoreError.notFound(missing)) { try await store.pin(id: missing) }
        await #expect(throws: VocabularyStoreError.notFound(missing)) { try await store.remove(id: missing) }
    }

    // MARK: blocking and learning

    @Test func aBlockedEntryCannotBeRelearned() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let e = try await store.add(text: "Claude", now: t0)
        try await store.block(id: e.id)
        for source in [VocabularyEntry.Source.history, .cleanup, .choice] {
            let learned = try await store.learn(text: "claude", source: source, id: UUID(), now: t0.addingTimeInterval(10))
            #expect(learned == nil)
        }
        let snap = try await store.snapshot()
        #expect(snap.entries.count == 1)
        #expect(snap.entries[0].blocked)
        #expect(snap.entries[0].score == e.score)
        #expect(snap.entries[0].recentIDs.isEmpty)
    }

    @Test func aManualAddOfABlockedTextUnblocksIt() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let e = try await store.add(text: "Claude", now: t0)
        try await store.block(id: e.id)
        let again = try await store.add(text: "Claude", now: t0)
        #expect(again.id == e.id)
        #expect(!again.blocked)
    }

    @Test func learningCreatesThenReinforcesOncePerId() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let d1 = UUID(), d2 = UUID()
        let first = try await store.learn(text: "Grünwald", kind: .place, source: .history, knownIn: ["de"], id: d1, now: t0)
        #expect(first?.source == .history)
        #expect(first?.score == 1)
        try await store.learn(text: "Grünwald", source: .history, id: d1, now: t0.addingTimeInterval(5))
        #expect(try await store.snapshot().entries[0].score == 1)
        try await store.learn(text: "Grünwald", source: .history, id: d2, now: t0.addingTimeInterval(10))
        let e = try await store.snapshot().entries[0]
        #expect(e.score == 2)
        #expect(e.recentIDs == [d1, d2])
        #expect(e.lastSeen == t0.addingTimeInterval(10))
    }

    @Test func recentIDsKeepOnlyTheLastSixteen() {
        var e = VocabularyEntry(text: "x", lastSeen: t0)
        let ids = (0..<20).map { _ in UUID() }
        for id in ids { e.remember(id) }
        #expect(e.recentIDs == Array(ids.suffix(16)))
        #expect(e.remember(ids[19]) == false)
    }

    // MARK: pending lists

    @Test func pendingTermsAreCappedAtFiveHundredEvictingTheLowestEffectiveScore() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        let now = t0
        let halfLife = Decay.defaultHalfLife
        try await store.update(now: now) { snap in
            // 500 recent terms, scores 10...509.
            snap.pendingTerms = (0..<500).map { PendingTerm(text: "t\($0)", score: Double(10 + $0), lastSeen: now) }
            snap.pendingFixes = (0..<500).map { PendingFix(raw: "r\($0)", target: "T", score: Double(10 + $0), lastSeen: now) }
        }
        #expect(try await store.snapshot().pendingTerms.count == 500)
        try await store.update(now: now, halfLife: halfLife) { snap in
            // High raw score but four half-lives old: effective 1000/16 = 62.5, still above t0 (10)...
            snap.pendingTerms.append(PendingTerm(text: "old-strong", score: 1000, lastSeen: now.addingTimeInterval(-4 * halfLife)))
            // ...while this one is the lowest of all: 20 / 2^10 ≈ 0.02.
            snap.pendingTerms.append(PendingTerm(text: "old-weak", score: 20, lastSeen: now.addingTimeInterval(-10 * halfLife)))
            snap.pendingFixes.append(PendingFix(raw: "weak", target: "T", score: 0.5, lastSeen: now))
        }
        let snap = try await store.snapshot()
        #expect(snap.pendingTerms.count == 500)
        #expect(snap.pendingFixes.count == 500)
        let texts = Set(snap.pendingTerms.map(\.text))
        #expect(!texts.contains("old-weak"))
        #expect(!texts.contains("t0"))  // effective 10, now the lowest after old-weak
        #expect(texts.contains("old-strong"))
        #expect(texts.contains("t2"))
        #expect(!snap.pendingFixes.contains { $0.raw == "weak" })
        #expect(snap.pendingFixes.contains { $0.raw == "r0" })
    }

    @Test func decayHalvesTheScorePerHalfLife() {
        let h: TimeInterval = 1000
        #expect(Decay.effectiveScore(8, lastSeen: t0, now: t0, halfLife: h) == 8)
        #expect(Decay.effectiveScore(8, lastSeen: t0, now: t0.addingTimeInterval(h), halfLife: h) == 4)
        #expect(Decay.effectiveScore(8, lastSeen: t0, now: t0.addingTimeInterval(3 * h), halfLife: h) == 1)
        #expect(Decay.effectiveScore(8, lastSeen: t0.addingTimeInterval(h), now: t0, halfLife: h) == 8)
    }

    // MARK: an added alias removes a learned sibling

    @Test func addingAnAliasRemovesALearnedEntryWithThatText() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        try await store.learn(text: "kloud", source: .history, id: UUID(), now: t0)
        try await store.update { $0.pendingTerms.append(PendingTerm(text: "KLOUD", ids: [UUID()], lastSeen: self.t0)) }
        try await store.add(text: "Claude", aliases: ["Kloud"], now: t0)
        let snap = try await store.snapshot()
        #expect(snap.entries.map(\.text) == ["Claude"])
        #expect(snap.pendingTerms.isEmpty)
    }

    @Test func addingAnAliasToAnExistingEntryRemovesTheLearnedSiblingToo() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        try await store.add(text: "Claude", now: t0)
        try await store.learn(text: "kloud", source: .cleanup, now: t0)
        try await store.add(text: "Claude", aliases: ["kloud"], now: t0)
        #expect(try await store.snapshot().entries.map(\.text) == ["Claude"])
    }

    @Test func addingAnAliasKeepsAManualOrPinnedEntryWithThatText() async throws {
        let url = tempURL()
        defer { cleanup(url) }
        let store = VocabularyStore(fileURL: url)
        try await store.add(text: "kloud", now: t0)
        let pinned = try await store.learn(text: "klaud", source: .history, now: t0)
        try await store.pin(id: try #require(pinned).id)
        try await store.add(text: "Claude", aliases: ["kloud", "klaud"], now: t0)
        #expect(try await store.snapshot().entries.map(\.text) == ["kloud", "klaud", "Claude"])
    }
}
