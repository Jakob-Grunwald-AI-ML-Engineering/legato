import Foundation
import LegatoAgent
import LegatoClaude
import LegatoCore
import LegatoRoom
import LegatoVocabulary
import Synchronization
import Testing
@testable import LegatoAppServices

/// Captures the serialized request before a provider can respond. No network, model or API key.
private final class RequestCapture: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        requests.withLock { $0.append(request) }
        return AsyncThrowingStream { $0.finish() }
    }

    func payload() throws -> [String: Any] {
        let data = try #require(requests.withLock { $0.last })
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }
}

@Suite struct ReviewedPersonalizationTests {
    private func record(_ store: CorrectionStore, original: String, fixed: String) async throws {
        let now = Date()
        var tracker = try #require(CorrectionTracker(dictationID: UUID().uuidString, rawText: original, insertedText: original,
            snapshot: original, platform: "test", localeIdentifier: "en-US", now: now))
        tracker.observe(fixed, origin: .keyboard, now: now)
        try await store.append(#require(tracker.settle(now: now.addingTimeInterval(2))))
    }

    @Test @MainActor func heldOutSentencesUseOnlyApprovedApplicableEvidenceAndHonorRevocation() async throws {
        let rig = VocabularyRig()
        defer { rig.cleanUp() }
        try await rig.service.store.add(text: "Kubernetes")
        let store = CorrectionStore(root: rig.url.deletingLastPathComponent())
        for opening in ["Call", "Ask"] {
            try await record(store, original: "\(opening) Greenwald privately", fixed: "\(opening) Grunwald privately")
            try await record(store, original: "\(opening) again, thanks!", fixed: "\(opening) again, thanks.")
        }
        let candidates = try await store.reviewSnapshot().candidates
        let vocabulary = try #require(candidates.first { $0.kind == .vocabulary })
        let style = try #require(candidates.first { $0.kind == .style })
        let preferences = RequestVocabulary(fileURL: rig.url)
        let capture = RequestCapture()
        let cleaner = SentenceCleanupClient(client: capture, personalization: { await preferences.cleanup(for: $0) })
        func payload(_ text: String) async throws -> [String: Any] {
            _ = try? await cleaner.cleanTake(.init(takeID: "held-out", text: text))
            return try capture.payload()
        }

        let heldOut = "Email Greenwald the agenda, thanks!"
        let baseline = try await payload(heldOut)
        #expect((baseline["vocabulary"] as? [String]) == [])
        #expect(baseline["reviewedExamples"] == nil)

        let sockets = SocketBox()
        let engine = DictationEngine(sink: RecordingSink(), sonioxKey: { "fixture" }, makeSocket: { sockets.make() }, vocabularyURL: rig.url)
        engine.open()
        try await store.setReview(.approved, for: vocabulary)
        try await store.setReview(.approved, for: style)
        await engine.activate()
        let socket = try #require(sockets.at(0))
        let configured = await socket.sent.compactMap { frame -> String? in
            if case let .text(value) = frame, value.contains("stt-rt") { return value }
            return nil
        }
        await engine.close()
        let request = try #require(configured.first)
        #expect(request.contains("Grunwald"))
        #expect(!request.contains("Greenwald") && !request.contains("privately") && !request.contains("thanks"))

        let personalized = try await payload(heldOut)
        #expect((personalized["vocabulary"] as? [String]) == ["Grunwald"])
        let examples = try #require(personalized["reviewedExamples"] as? [[String: String]])
        #expect(examples.contains(["before": "Greenwald", "after": "Grunwald"]))
        #expect(examples.contains(["before": "thanks!", "after": "thanks."]))
        let unrelated = try await payload("Send the weather forecast")
        #expect((unrelated["vocabulary"] as? [String]) == [])
        #expect(unrelated["reviewedExamples"] == nil)

        try await store.setPersonalizationEnabled(false)
        #expect(try await payload(heldOut)["reviewedExamples"] == nil)
        #expect(await preferences.sonioxTerms() == ["Kubernetes"])
        try await store.setPersonalizationEnabled(true)
        try await store.delete(id: vocabulary.records[0].id)
        try await store.setReview(.dismissed, for: style)
        let revoked = try await payload(heldOut)
        #expect((revoked["vocabulary"] as? [String]) == [])
        #expect(revoked["reviewedExamples"] == nil)
    }
}

extension ReviewedPersonalizationTests {
    @Test func editedRecognitionSpellingReplacesItsLearnedEntryInACappedRequest() async throws {
        let rig = VocabularyRig()
        defer { rig.cleanUp() }
        let now = Date()
        try await rig.service.store.update { snapshot in
            snapshot.entries = (0..<67).map { VocabularyEntry(text: "OtherTerm\($0)", source: .history, score: 10, lastSeen: now) }
            snapshot.entries.append(VocabularyEntry(text: "Kemas", source: .history, score: 20, lastSeen: now))
        }
        let store = CorrectionStore(root: rig.url.deletingLastPathComponent())
        let takes = [UUID(), UUID()]
        for id in takes {
            try await store.replaceRecognizedEvidence(takeID: id.uuidString, with: [
                .recognized(takeID: id, term: "Kemas", date: now, localeIdentifier: "en", promotionCount: 2)
            ])
        }
        let request = RequestVocabulary(fileURL: rig.url)
        #expect(await request.sonioxTerms().first == "Kemas")
        let candidate = try #require(try await store.activeCandidates().first)
        try await store.editSpelling("Kemaris", for: candidate)
        let revised = await request.sonioxTerms { _ in .init(textBeforeCursor: "Kemas") }
        #expect(revised.count == VocabularyService.engineHintLimit)
        #expect(revised.contains("Kemaris"))
        #expect(!revised.contains("Kemas"))

        var keyboard = try await rig.service.store.snapshot()
        let original = try #require(keyboard.entry(forText: "Kemas"))
        let choices = try await store.keyboardCandidates()
        keyboard.applySpellingEdits(from: choices)
        for choice in choices { keyboard.overlay(choice, automaticSource: .choice) }
        var pairs = WordPairModel()
        pairs.observe(text: "call Kemas", at: now)
        #expect(await WordSuggester.completions(prefix: "Kem", previous: ["call"], snapshot: keyboard,
                                                pairs: pairs, completer: nil, languages: ["en"]) == ["Kemaris"])

        try await rig.service.store.pin(id: original.id)
        let pinned = await request.sonioxTerms()
        #expect(pinned.contains("Kemaris") && pinned.contains("Kemas"))
        try await rig.service.store.unpin(id: original.id)
        try await store.replaceRecognizedEvidence(takeID: takes[0].uuidString, with: [])
        let withdrawn = await request.sonioxTerms()
        #expect(withdrawn.contains("Kemas"))
        #expect(!withdrawn.contains("Kemaris"))
    }
}
