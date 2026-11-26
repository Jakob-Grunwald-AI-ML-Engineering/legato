import Foundation
import Testing
@testable import LegatoCore

struct CorrectionReviewTests {
    private func edit(_ take: String, from: String = "Greenwald", to: String = "Grunwald", locale: String = "en", raw: String? = nil) -> CorrectionRecord {
        CorrectionRecord(date: Date(), dictationID: take, platform: "Mac", localeIdentifier: locale, rawText: raw ?? from, insertedText: from,
                         beforeText: from, afterText: to, removed: from, replacement: to, contextBefore: "", contextAfter: "", origin: .observedHost)
    }

    @Test func reviewsFollowSurvivingIndependentEvidenceAcrossReaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ui = CorrectionStore(root: root), provider = CorrectionStore(root: root)
        let first = edit("one"), second = edit("two")
        try await ui.append(first)
        try await ui.append(first)
        #expect(try await ui.reviewSnapshot().candidates.isEmpty)
        try await provider.append(second)
        let candidate = try #require(try await ui.reviewSnapshot().candidates.first)
        #expect(candidate.kind == .vocabulary)
        #expect(candidate.basis == .recognition)
        #expect(Set(candidate.records.map(\.id)) == [first.id, second.id])
        #expect(try await provider.approvedCandidates().isEmpty)
        try await ui.setReview(.approved, for: candidate)
        #expect(try await provider.approvedCandidates().map(\.after) == ["Grunwald"])
        try await ui.setPersonalizationEnabled(false)
        #expect(try await provider.approvedCandidates().isEmpty)
        try await ui.setPersonalizationEnabled(true)
        try await ui.setReview(.dismissed, for: candidate)
        #expect(try await provider.approvedCandidates().isEmpty)
        try await ui.setReview(.approved, for: candidate)
        try await ui.delete(id: first.id)
        #expect(try await provider.approvedCandidates().isEmpty)
        try await ui.delete(id: second.id)
        try await ui.append(edit("three"))
        try await ui.append(edit("four"))
        #expect(try await provider.reviewSnapshot().candidates.first?.state == .pending)
    }

    @Test func distinguishesStyleSourceLanguageAndChangesOfMind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CorrectionStore(root: root)
        for take in ["1", "2"] {
            try await store.append(edit(take, from: "Thanks!", to: "Thanks."))
            try await store.append(edit("cleanup-" + take, raw: "Grunwald"))
            try await store.append(edit("intent-" + take, from: "coffee", to: "bread"))
        }
        try await store.append(edit("de", locale: "de"))
        let result = try await store.reviewSnapshot().candidates
        #expect(result.count == 2)
        #expect(result.first { $0.kind == .style }?.after == "Thanks.")
        #expect(result.first { $0.kind == .vocabulary }?.basis == .cleanup)
        var undo = edit("1", from: "Thanks.", to: "Thanks!")
        undo.insertedText = "Thanks!"
        try await store.append(undo)
        #expect(try await store.reviewSnapshot().candidates.map(\.kind) == [.vocabulary])
    }
}
