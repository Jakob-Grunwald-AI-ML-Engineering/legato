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

private actor HintEvents {
    var values: [Envelope] = []
    func add(_ event: Envelope) { values.append(event) }
}

private func observeHints(_ room: Room, _ values: HintEvents) async -> Task<Void, Never> {
    let stream = await room.subscribe(participant: .logger, channels: [.hint, .asrTail])
    return Task { for await event in stream { await values.add(event) } }
}

private func waitForHint(_ values: HintEvents) async -> Envelope? {
    for _ in 0..<100 {
        if let hint = await values.values.first(where: { $0.channel == .hint }) { return hint }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return nil
}

private func segment(_ room: Room, words: [Word], at time: Double, reason: String) async throws {
    try await room.publish(channel: .asrSegment, participant: .segmenter,
                           payload: .object(["words": try .encoding(words), "metadata": .object(["reason": .string(reason)])]), tOrigin: time)
}

@Test func tappedSpeechBuffersPunctuationUntilSilenceAndNextChunkIsGeneral() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "target", text: "wrong")])
    let original = try #require(await room.documentSnapshot.lines.first)
    let binder = HintBinder(room: room)
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: original.id, wordID: "target", timestamp: 100)
    // No old four-second/three-word limit; punctuation is not the silence boundary.
    try await segment(room, words: [Word(text: "Use"), Word(text: "the"), Word(text: "full"), Word(text: "name.")], at: 110, reason: "punctuation")
    try await segment(room, words: [Word(text: "Morgan", confidence: 0.42), Word(text: "Grunwald", language: "de")], at: 111, reason: "words")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await room.documentSnapshot.text == "wrong")
    #expect(await events.values.filter { $0.channel == .hint }.isEmpty)
    let boundary = try #require(Channel(rawValue: "asr.boundary"))
    try await room.publish(channel: boundary, participant: .segmenter,
                           payload: .object(["reason": .string("endpoint")]), tOrigin: 112)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["event"] == .string("targeted.speech"))
    #expect(hint.payload["lineID"] == .string(original.id))
    #expect(hint.payload["wordID"] == .string("target"))
    #expect(hint.payload["lineVersion"] == .number(Double(original.version)))
    #expect(hint.payload["text"] == .string("Use the full name. Morgan Grunwald"))
    let words = try #require(hint.payload["words"]).decode([Word].self)
    #expect(words[4].confidence == 0.42 && words[5].language == "de")
    #expect(await room.documentSnapshot.lines.first?.words.first?.pinned == false)
    try await segment(room, words: [Word(text: "ordinary")], at: 113, reason: "punctuation")
    let snapshot = try await settled(room) { $0.lines.count == 2 }
    #expect(snapshot.text == "wrong\nordinary")
    await binder.stop()
}

@Test func retapRetargetsAndDelayedPreTapSpeechDoesNotConsumeCapture() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "a", text: "first"), Word(id: "b", text: "second")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let binder = HintBinder(room: room)
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: line.id, wordID: "a", timestamp: 100)
    try await segment(room, words: [Word(text: "discarded")], at: 100.2, reason: "punctuation")
    try await Task.sleep(for: .milliseconds(20))
    try await binder.tap(lineID: line.id, wordID: "b", timestamp: 101)
    try await segment(room, words: [Word(text: "old")], at: 99, reason: "gap")
    try await segment(room, words: [Word(text: "replacement")], at: 102, reason: "punctuation")
    let boundary = try #require(Channel(rawValue: "asr.boundary"))
    try await room.publish(channel: boundary, participant: .segmenter, payload: .object(["reason": .string("gap")]), tOrigin: 103)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["wordID"] == .string("b"))
    #expect(hint.payload["text"] == .string("replacement"))
    #expect(await room.documentSnapshot.text == "first second\nold")
    await binder.stop()
    await binder.start()
    try await segment(room, words: [Word(text: "after-stop")], at: 104, reason: "punctuation")
    let after = try await settled(room) { $0.lines.count == 3 }
    #expect(after.text == "first second\nold\nafter-stop")
    await binder.stop()
}

@Test func mixedPreTapSegmentKeepsOrdinaryPrefixButDrainsTargetedSuffixBeforeFinalPass() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "target", text: "Alex")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let binder = HintBinder(room: room)
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: line.id, wordID: "target", timestamp: 100.5)
    let metadata: JSONValue = .object(["t0": .number(0), "t1": .number(1.2),
        "timings": .array([.object(["t0": .number(0), "t1": .number(0.2)]),
                           .object(["t0": .number(1), "t1": .number(1.2)])]), "reason": .string("punctuation")])
    try await room.publish(channel: .asrSegment, participant: .segmenter,
        payload: .object(["words": try .encoding([Word(text: "earlier"), Word(text: "Morgan")]), "metadata": metadata]), tOrigin: 100)
    _ = try await settled(room) { $0.lines.count == 2 }
    try await room.micOff(transcriberDraining: true)
    await room.finishTranscription()
    #expect(await room.state == .trailing, "Appending the ordinary prefix must not resolve the targeted remainder")
    try await room.publish(channel: .asrBoundary, participant: .segmenter,
                           payload: .object(["reason": .string("finalize")]), tOrigin: 101.2)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["text"] == .string("Morgan"))
    #expect(hint.payload["speechStart"] == .number(101))
    #expect(hint.payload["speechEnd"] == .number(101.2))
    #expect(await room.documentSnapshot.text == "Alex\nearlier")
    for _ in 0..<100 {
        if await room.state == .finalPass { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await room.state == .finalPass)
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

@Test func interceptedFinalSegmentMustDrainBeforeFinalPass() async throws {
    let room = Room(segmentRouting: .intercepted)
    let segment = try await room.publishSegment(words: [Word(text: "last")])
    try await room.micOff(transcriberDraining: true)
    await room.finishTranscription()
    #expect(await room.state == .trailing)
    try await room.appendSegment(words: [Word(text: "last")], causedBy: segment.id)
    #expect(await room.state == .finalPass)
    #expect(await room.documentSnapshot.text == "last")

    let hintRoom = Room(segmentRouting: .intercepted)
    let hint = try await hintRoom.publishSegment(words: [Word(text: "hint")])
    try await hintRoom.micOff(transcriberDraining: true)
    await hintRoom.finishTranscription()
    #expect(await hintRoom.state == .trailing)
    await hintRoom.resolveSegment(hint.id)
    #expect(await hintRoom.state == .finalPass)

    let insertRoom = Room(segmentRouting: .intercepted)
    try await insertRoom.publishSegment(words: [Word(text: "pending")])
    _ = try await insertRoom.insert()
    #expect(await insertRoom.state == .done)
}
