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

    @Test func separateSourcesInOneTakeCountOnceAndSuppressionSurvivesNewForms() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CorrectionStore(root: root)
        let first = edit("one", from: "schemas and Canvas today", to: "Kemas and Kemas today")
        try await store.append(first)
        try await store.recordTermEvidence(TermEvidence(term: "Kemas", original: "schemas", takeID: "ONE",
            date: Date(), localeIdentifier: "en", origin: .selection, promotionCount: 2))
        #expect(try await store.activeCandidates().isEmpty)
        try await store.append(edit("two", from: "Call Canvas about layouts", to: "Call Kemas about drafts"))
        let term = try #require(try await store.activeCandidates().first)
        #expect(term.sources == ["Canvas", "schemas"])
        #expect(term.isAutomatic)
        #expect(term.supportCount == 2)
        try await store.editSpelling("KEMAS", for: term)
        let edited = try #require(try await store.activeCandidates().first)
        #expect(edited.after == "KEMAS")
        #expect(edited.approvedSource == nil)
        try await store.setReview(.dismissed, for: edited)
        try await store.append(edit("three", from: "Chemist", to: "Kemas"))
        #expect(try await store.activeCandidates().isEmpty)
        #expect(try await store.keyboardCandidates().isEmpty)
    }

    @Test func deletingTakeOrDisablingLearningWithdrawsLinkedSupport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CorrectionStore(root: root)
        try await store.append(edit("first"))
        try await store.setPersonalizationEnabled(false)
        try await store.append(edit("disabled"))
        try await store.setPersonalizationEnabled(true)
        #expect(try await store.activeCandidates().isEmpty)
        try await store.append(edit("second"))
        #expect(try await store.activeCandidates().count == 1)
        try await store.invalidateVocabularyEvidence(takeID: "SECOND")
        #expect(try await store.activeCandidates().isEmpty)
        try await store.recordTermEvidence(TermEvidence(term: "Grunwald", takeID: "second",
            date: Date(), localeIdentifier: "en", origin: .typed, promotionCount: 2))
        #expect(try await store.activeCandidates().isEmpty)
        #expect(try await store.recent().count == 3)
    }
}
