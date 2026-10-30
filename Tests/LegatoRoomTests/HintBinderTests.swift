import Foundation
import Testing
import LegatoComposerDoc
import LegatoVocabulary
@testable import LegatoRoom

private func settled(_ room: Room, until predicate: (DocumentSnapshot) -> Bool) async throws -> DocumentSnapshot {
    for _ in 0..<100 {
        let snapshot = await room.documentSnapshot
        if predicate(snapshot) { return snapshot }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Room participant did not settle")
    return await room.documentSnapshot
}

@Test func alternativesPickPinsAndEmitsIntent() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "w", text: "Kubernetis", confidence: 0.3)])
    let lineID = try #require(await room.documentSnapshot.lines.first?.id)
    let binder = HintBinder(room: room)
    await binder.start()
    let stream = await room.subscribe(participant: .liveAgent, channels: [.userIntent])
    var iterator = stream.makeAsyncIterator()
    try await binder.pick(lineID: lineID, wordID: "w", text: "Kubernetes")
    let intent = try #require(await iterator.next()).payload.decode(WordIntent.self)
    #expect(intent.event == "pick")
    let word = try #require(await room.documentSnapshot.lines.first?.words.first)
    #expect(word.text == "Kubernetes" && word.pinned)
    await binder.stop()
}

@Test(arguments: [(-0.3, 2, false), (0.2, 2, true), (4.1, 1, false), (0.2, 4, false)])
func hintUsesAudioStartRatherThanDelivery(offset: Double, count: Int, direct: Bool) async throws {
    let room = Room(segmentRouting: .intercepted, clock: { 999 })
    try await room.appendSegment(words: [Word(id: "w", text: "wrong")])
    let lineID = try #require(await room.documentSnapshot.lines.first?.id)
    let binder = HintBinder(room: room)
    await binder.start()
    try await binder.tap(lineID: lineID, wordID: "w", timestamp: 100)
    let words = (0..<count).map { Word(text: "hint\($0)") }
    try await room.publishSegment(words: words, tOrigin: 100 + offset)
    let snapshot = try await settled(room) { direct ? $0.lines.first?.words.first?.pinned == true : $0.lines.count == 2 }
    #expect(snapshot.lines.count == (direct ? 1 : 2))
    #expect(snapshot.lines.first?.words.first?.pinned == direct)
    await binder.stop()
}

@Test func firstPreTapSegmentClosesHintWindow() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "w", text: "wrong")])
    let lineID = try #require(await room.documentSnapshot.lines.first?.id)
    let binder = HintBinder(room: room)
    await binder.start()
    try await binder.tap(lineID: lineID, wordID: "w", timestamp: 100)
    try await room.publishSegment(words: [Word(text: "old")], tOrigin: 99.8)
    try await room.publishSegment(words: [Word(text: "new")], tOrigin: 100.2)
    let snapshot = try await settled(room) { $0.lines.count == 3 }
    #expect(snapshot.lines.first?.words.first?.text == "wrong")
    await binder.stop()
}

@Test func alternativesPopulateLowConfidenceWords() async throws {
    let room = Room()
    let store = VocabularyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID()).json"))
    try await store.add(text: "Kubernetes")
    let participant = AlternativesParticipant(room: room, store: store, spellChecker: UnknownWords())
    await participant.start()
    try await room.publishSegment(words: [Word(id: "w", text: "Kubernetis", confidence: 0.3), Word(id: "v", text: "Grunwald", confidence: 0.9)])
    let snapshot = try await settled(room) { $0.lines.first?.words.first?.alternatives != nil }
    #expect(snapshot.lines.first?.words.first?.alternatives?.contains("Kubernetes") == true)
    #expect(snapshot.lines.first?.words.last?.alternatives == nil)
    await participant.stop()
}

private struct UnknownWords: SpellChecking {
    func isKnown(_ word: String, language: String) async -> Bool { false }
    func guesses(for word: String, language: String) async -> [String] { [] }
}
private struct NoEntities: EntityTagging {
    func entities(in text: String, language: String) -> [EntitySpan] { [] }
}

@Test func agentFixPromotesAcrossRunsIntoSonioxAndKeyboard() async throws {
    let store = VocabularyStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("composer-learning-\(UUID()).json"))
    let learner = VocabularyLearner(store: store, spellChecker: UnknownWords(), tagger: NoEntities(), languages: ["en"])
    for index in 0..<2 {
        let room = Room()
        let participant = AlternativesParticipant(room: room, store: store, learner: learner)
        await participant.start()
        try await room.publishSegment(words: [Word(text: "Kubernetis", confidence: 0.8, language: "en")])
        let line = try #require(await room.documentSnapshot.lines.first)
        // A snapshot is consumed before its following operation on the ordered subscription.
        try await room.applyDocument([.replaceInLine(lineID: line.id, old: "Kubernetis", new: "Kubernetes")], origin: .agent, versions: [line.id: line.version])
        for _ in 0..<100 {
            let snapshot = try await store.snapshot()
            if index == 0 ? !snapshot.pendingFixes.isEmpty : snapshot.entry(forText: "Kubernetes") != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await participant.stop()
    }
    let snapshot = try await store.snapshot()
    #expect(snapshot.entry(forText: "Kubernetes")?.aliases.contains("Kubernetis") == true)
    #expect(HintSelector(languages: ["en"]).hints(from: snapshot, for: .soniox).contains { $0.text == "Kubernetes" })
    let completions = await WordSuggester.completions(prefix: "Kube", previous: [], snapshot: snapshot, pairs: nil, completer: nil, languages: ["en"])
    #expect(completions.contains("Kubernetes"))
}
