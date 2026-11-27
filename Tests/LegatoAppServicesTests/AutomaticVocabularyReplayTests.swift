import Foundation
import LegatoAgent
import LegatoClaude
import LegatoCore
import LegatoSoniox
import LegatoVocabulary
import Synchronization
import Testing
@testable import LegatoAppServices

/// Fixed chronological replay. The transport records serialized requests and makes no provider call.
private final class VocabularyReplayTransport: MessagesStreaming {
    private let request = Mutex(Data())

    func stream(request data: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        request.withLock { $0 = data }
        return AsyncThrowingStream { $0.finish() }
    }

    func userMessage() throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: request.withLock { $0 }) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        return try #require(messages.first?["content"] as? String)
    }
}

@Suite struct AutomaticVocabularyReplayTests {
    @Test func chronologicalNamesAndOrdinaryWords() async throws {
        let rig = VocabularyRig()
        defer { rig.cleanUp() }
        let root = rig.url.deletingLastPathComponent()
        let store = CorrectionStore(root: root)
        let request = RequestVocabulary(fileURL: rig.url)
        for (session, raw, edited) in [
            ("business-en", "Email schemas today", "Email Kemas today"),
            ("business-de", "Canvas bitte anrufen", "Kemas bitte anrufen")
        ] {
            let date = Date(timeIntervalSince1970: session == "business-en" ? 1_800_000_000 : 1_800_010_000)
            var tracker = try #require(CorrectionTracker(dictationID: session, rawText: raw, insertedText: raw,
                snapshot: raw, platform: "macOS", localeIdentifier: "en_DE", now: date))
            tracker.observe(edited, origin: .observedHost, now: date)
            try await store.append(#require(tracker.settle(now: date.addingTimeInterval(2))))
        }

        let clock = ContinuousClock()
        let started = clock.now
        let terms = await request.sonioxTerms()
        let latency = started.duration(to: clock.now)
        let config = try SonioxConfig(terms: terms).message()
        let object = try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let context = try #require(object["context"] as? [String: Any])
        let wire = try #require(context["terms"] as? [String])
        let transport = VocabularyReplayTransport()
        // Even a relevant name in the current field must not turn a different ordinary word into a draft match.
        let business = VocabularyTopicContext(textBeforeCursor: "Spoke to Kemas")
        let clean = SentenceCleanupClient(client: transport, personalization: { await request.cleanup(for: $0, context: business) })
        let ordinary = "Review the database schemas."
        _ = try? await clean.cleanTake(.init(takeID: "technical-held-out", text: ordinary))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(try transport.userMessage().utf8)) as? [String: Any])
        let cleanupTerms = try #require(payload["vocabulary"] as? [String])
        let magic = InstructionRunner(client: transport, model: { .haiku }, personalization: { await request.cleanup(for: $0, context: business) })
        let field = InstructionContext(selection: ordinary)
        _ = try? await magic.run(instruction: "Make this shorter", context: field) { _ in field }
        let magicMentionsName = try transport.userMessage().contains("Kemas")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var bytes = 0
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "json" { bytes += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        }
        print("Vocabulary replay: wire=\(wire) cleanup=\(cleanupTerms) magicMentionsName=\(magicMentionsName) firstHintRead=\(latency) jsonBytes=\(bytes)")
        #expect(wire == ["Kemas"])
        #expect(!cleanupTerms.contains("Kemas"))
        #expect(!magicMentionsName)
    }

    @Test func recentSpeechOrdersExactMatchesInSerializedCleanup() async throws {
        let rig = VocabularyRig()
        defer { rig.cleanUp() }
        let historyURL = rig.url.deletingLastPathComponent().appending(path: "history.jsonl")
        let history = LearningHistoryStore(JSONLHistoryStore(fileURL: historyURL), vocabulary: rig.service)
        await history.warmTopicContext()
        for name in ["Kemas", "Badhri"] { try await rig.service.store.add(text: name) }
        var previous = DictationEntry(date: Date(), text: "I just spoke with Badhri.", localeIdentifier: "en",
                                      engineID: "soniox", duration: 2)
        previous.recognitionHints = []
        try await history.upsert(previous)
        await rig.service.waitForLearning()
        let draft = "Kemas and Badhri are attending."
        for contextual in [false, true] {
            let request = RequestVocabulary(fileURL: rig.url, history: contextual ? history : nil)
            let transport = VocabularyReplayTransport()
            let client = SentenceCleanupClient(client: transport, personalization: { await request.cleanup(for: $0) })
            _ = try? await client.cleanTake(.init(takeID: "cleanup-order", text: draft))
            let message = try transport.userMessage()
            let payload = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
            let terms = try #require(payload["vocabulary"] as? [String])
            #expect(terms == (contextual ? ["Badhri", "Kemas"] : ["Kemas", "Badhri"]))
            print("Topic cleanup contextual=\(contextual) vocabulary=\(terms)")
        }
    }

    @Test func quickSendThenIndependentTyping() async throws {
        let rig = VocabularyRig()
        defer { rig.cleanUp() }
        let store = CorrectionStore(root: rig.url.deletingLastPathComponent())
        let request = RequestVocabulary(fileURL: rig.url)
        let now = Date()
        let raw = "Ask Patrice for the drawings"
        var edit = try #require(CorrectionTracker(dictationID: "chat-1", rawText: raw, insertedText: raw,
            snapshot: raw, platform: "iOS", localeIdentifier: "en_US", now: now))
        edit.observe("Ask Badhri for the drawings", origin: .keyboard, now: now)
        edit.observe("\n", origin: .observedHost, now: now.addingTimeInterval(0.2))
        let pendingRecord = edit.settle(now: now.addingTimeInterval(0.2))
        let record = try #require(pendingRecord)
        try await store.append(record)
        #expect(await request.sonioxTerms().isEmpty)
        let typed = TermEvidence(term: "Badhri", date: now.addingTimeInterval(60), localeIdentifier: "en_US", origin: .typed)
        try await store.recordTermEvidence(typed)
        try await store.recordTermEvidence(typed)
        #expect(await request.sonioxTerms() == ["Badhri"])
        try await store.deleteTermEvidence(id: typed.id)
        #expect(await request.sonioxTerms().isEmpty)
    }

    /// The same observed actions drive each comparison. Held-out prompts add no evidence.
    @Test func compareKeyboardFeedbackPolicies() async throws {
        let date = Date()
        var pairs = WordPairModel(languages: ["en", "de"])
        pairs.observe(text: "Review database schemas", at: date)
        var noAlias = VocabularySnapshot()
        noAlias.entries = [VocabularyEntry(text: "Kemas", source: .choice, lastSeen: date),
                           VocabularyEntry(text: "Badhri", source: .choice, lastSeen: date)]
        var hardAlias = noAlias
        hardAlias.entries[0].aliases = ["schemas", "Canvas"]
        for (name, snapshot) in [("typed pairs", VocabularySnapshot()), ("global alias", hardAlias), ("spelling only", noAlias)] {
            let afterDatabase = WordSuggester.predictions(previous: ["database"], pairs: pairs, snapshot: snapshot, now: date)
            let kem = await WordSuggester.completions(prefix: "Kem", previous: [], snapshot: snapshot, pairs: pairs,
                completer: nil, languages: ["en", "de"], now: date)
            let bad = await WordSuggester.completions(prefix: "Bad", previous: [], snapshot: snapshot, pairs: pairs,
                completer: nil, languages: ["en", "de"], now: date)
            if name == "spelling only" {
                #expect(afterDatabase.first == "schemas")
                #expect(kem.first == "Kemas")
                #expect(bad.first == "Badhri")
            }
            print("Keyboard policy \(name): database=\(afterDatabase) Kem=\(kem) Bad=\(bad)")
        }
    }

    /// An opt-in sample of cold and cached request reads with a longer synthetic history.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGATO_VOCAB_BENCHMARK"] == "1"))
    func measureEvidenceHistory() async throws {
        let rig = VocabularyRig()
        defer { rig.cleanUp() }
        let store = CorrectionStore(root: rig.url.deletingLastPathComponent())
        let now = Date()
        for index in 0..<500 {
            let event = TermEvidence(term: "Badhri", takeID: "typing-\(index)",
                date: now.addingTimeInterval(Double(index)), localeIdentifier: "en_US", origin: .typed)
            try await store.recordTermEvidence(event)
        }
        let request = RequestVocabulary(fileURL: rig.url)
        let clock = ContinuousClock()
        let cold = await clock.measure { _ = await request.sonioxTerms() }
        let cached = await clock.measure { _ = await request.sonioxTerms() }
        let files = try FileManager.default.contentsOfDirectory(at: store.termEvidenceDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        let sizes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) }
        print("500 observations: cold=\(cold) cached=\(cached) files=\(files.count) bytes=\(sizes.compactMap(\.fileSize).reduce(0, +)) allocated=\(sizes.compactMap(\.totalFileAllocatedSize).reduce(0, +))")
    }

    /// Shadow only. Compare three policies on whole held-out utterances, with and without confidence.
    @Test func shadowSubstitutionsStayOffline() {
        let matcher = TermMatcher(terms: [.init(text: "Kemas", aliases: ["schemas", "Canvas"])])
        let samples: [(String, String, Double?)] = [
            ("Email Canvas tomorrow", "Email Kemas tomorrow", 0.41),
            ("Bitte schemas anrufen", "Bitte Kemas anrufen", nil),
            ("Review the database schemas", "Review the database schemas", 0.98),
            ("Paint on Canvas today", "Paint on Canvas today", nil),
            ("Wir nutzen Canvas heute", "Wir nutzen Canvas heute", 0.46)
        ]
        var retrievalFixed = 0, retrievalDamaged = 0, guardedFixed = 0, guardedDamaged = 0
        for (original, expected, confidence) in samples {
            guard let hit = matcher.hits(in: original).first else { continue }
            var tokens = original.split(separator: " ").map(String.init)
            tokens.replaceSubrange(hit.range, with: ["Kemas"])
            let proposal = tokens.joined(separator: " ")
            if original != expected && proposal == expected { retrievalFixed += 1 }
            if original == expected && proposal != expected { retrievalDamaged += 1 }
            // An illustrative cutoff for this offline comparison, never a delivery rule.
            if let confidence, confidence < 0.5 {
                if original != expected && proposal == expected { guardedFixed += 1 }
                if original == expected && proposal != expected { guardedDamaged += 1 }
            }
        }
        print("Shadow fixed/introduced: unchanged 0/0, retrieval \(retrievalFixed)/\(retrievalDamaged), guarded \(guardedFixed)/\(guardedDamaged)")
        #expect(retrievalDamaged > 0)
    }
}
