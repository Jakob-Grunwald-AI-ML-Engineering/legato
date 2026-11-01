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
    let stream = await room.subscribe(participant: .logger, channels: [.hint, .asrTail, .correctionDraft, .writingInstruction])
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
    try await Task.sleep(for: .milliseconds(20))
    #expect(await binder.requestSend(timestamp: 112))
    let boundary = try #require(Channel(rawValue: "asr.boundary"))
    try await room.publish(channel: boundary, participant: .segmenter,
                           payload: .object(["reason": .string("finalize")]), tOrigin: 112)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["event"] == .string("targeted.speech"))
    #expect(hint.payload["lineID"] == .string(original.id))
    #expect(hint.payload["wordID"] == .string("target"))
    #expect(hint.payload["lineVersion"] == .number(Double(original.version)))
    #expect(hint.payload["text"] == .string("Use the full name. Morgan Grunwald"))
    let words = try #require(hint.payload["words"]).decode([Word].self)
    #expect(words[4].confidence == 0.42 && words[5].language == "de")
    #expect(await room.documentSnapshot.lines.first?.words.first?.pinned == false)
    // Speech after the correction is the next instruction, not draft text.
    try await segment(room, words: [Word(text: "ordinary")], at: 113, reason: "punctuation")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await binder.hasUnsentInstruction)
    #expect(await room.documentSnapshot.text == "wrong")
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
    try await Task.sleep(for: .milliseconds(20))
    #expect(await binder.requestSend(timestamp: 102.5))
    let boundary = try #require(Channel(rawValue: "asr.boundary"))
    try await room.publish(channel: boundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]), tOrigin: 103)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["wordID"] == .string("b"))
    #expect(hint.payload["text"] == .string("replacement"))
    #expect(await room.documentSnapshot.text == "first second")
    let instructions = await events.values.filter { $0.channel == .writingInstruction }
    #expect(instructions.map { $0.payload["text"] } == [.string("old")], "The delayed pre-tap speech is a general instruction")
    await binder.stop()
    await binder.start()
    try await segment(room, words: [Word(text: "after-stop")], at: 104, reason: "punctuation")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await binder.hasUnsentInstruction)
    #expect(await room.documentSnapshot.text == "first second")
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
    try await Task.sleep(for: .milliseconds(30))
    #expect(await binder.hasUnsentInstruction)
    try await room.micOff(transcriberDraining: true)
    await room.finishTranscription()
    #expect(await room.state == .trailing, "Appending the ordinary prefix must not resolve the targeted remainder")
    #expect(await binder.requestSend(timestamp: 101.2))
    try await room.publish(channel: .asrBoundary, participant: .segmenter,
                           payload: .object(["reason": .string("finalize")]), tOrigin: 101.2)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["text"] == .string("Morgan"))
    #expect(hint.payload["speechStart"] == .number(101))
    #expect(hint.payload["speechEnd"] == .number(101.2))
    #expect(await room.documentSnapshot.text == "Alex", "The ordinary prefix is an instruction, sent on the same boundary")
    #expect(!(await binder.hasUnsentInstruction))
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

@Test func singleWordTapUsesTheQuoteRangeContract() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "word", text: "Alex")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let binder = HintBinder(room: room)
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: line.id, wordID: "word", timestamp: 100)
    try await segment(room, words: [Word(text: "Morgan")], at: 101, reason: "punctuation")
    try await Task.sleep(for: .milliseconds(20))
    #expect(await binder.requestSend(timestamp: 102))
    try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]), tOrigin: 102)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["selectedQuote"] == .string("Alex"))
    #expect(hint.payload["endLineID"] == .string(line.id))
    #expect(hint.payload["endWordID"] == .string("word"))
    #expect(hint.payload["lineVersions"] == .object([line.id: .number(Double(line.version))]))
    await binder.stop()
}

@Test func reverseCrossLineSelectionCapturesQuoteAndAllObservedVersions() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(text: "Hello"), Word(id: "start", text: "Alex")])
    try await room.appendSegment(words: [Word(text: "please"), Word(text: "confirm")])
    try await room.appendSegment(words: [Word(text: "tomorrow"), Word(id: "end", text: "at"), Word(text: "ten.")])
    let initial = await room.documentSnapshot
    let first = initial.lines[0], middle = initial.lines[1], last = initial.lines[2]
    let binder = HintBinder(room: room)
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    let cleared = await room.subscribe(participant: .logger, channels: [.asrTail])
    var clearing = cleared.makeAsyncIterator()
    // The same tap intent carries a dragged range, including a reverse drag.
    try await room.publish(channel: .userIntent, participant: .ui, payload: .object([
        "event": .string("tap"), "lineID": .string(last.id), "wordID": .string("end"),
        "endLineID": .string(first.id), "endWordID": .string("start"), "timestamp": .number(100)]))
    _ = await clearing.next() // Capture is established before changing a source line.
    try await room.applyDocument([.setKind(ids: [middle.id], kind: .quote)], origin: .agent, versions: [middle.id: middle.version])
    try await segment(room, words: [Word(text: "Make"), Word(text: "this"), Word(text: "shorter.")], at: 101, reason: "punctuation")
    try await Task.sleep(for: .milliseconds(20))
    #expect(await binder.requestSend(timestamp: 102))
    try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]), tOrigin: 102)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["lineID"] == .string(first.id))
    #expect(hint.payload["wordID"] == .string("start"))
    #expect(hint.payload["endLineID"] == .string(last.id))
    #expect(hint.payload["endWordID"] == .string("end"))
    #expect(hint.payload["selectedQuote"] == .string("Alex\nplease confirm\ntomorrow at"))
    #expect(hint.payload["lineVersions"] == .object(Dictionary(uniqueKeysWithValues: initial.lines.map { ($0.id, .number(Double($0.version))) })))
    let capturedLines = try #require(hint.payload["targetLines"]).decode([Line].self)
    #expect(capturedLines == initial.lines)
    #expect(await room.documentSnapshot.text == initial.text)
    await binder.stop()
}

@Test func dismissingSelectionDiscardsBufferedAndDelayedInstructionBeforeResumingGeneralSpeech() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "target", text: "Alex")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let binder = HintBinder(room: room)
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: line.id, wordID: "target", timestamp: 100)
    try await segment(room, words: [Word(text: "buffered instruction")], at: 101, reason: "punctuation")
    try await room.publish(channel: .userIntent, participant: .ui,
        payload: .encoding(WordIntent(event: "deselect", lineID: line.id, wordID: "target", timestamp: 102)))
    try await segment(room, words: [Word(text: "delayed instruction")], at: 101.5, reason: "punctuation")
    try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("old partial")]))
    try await room.publish(channel: .asrBoundary, participant: .segmenter,
                           payload: .object(["reason": .string("endpoint")]), tOrigin: 101.9)
    try await segment(room, words: [Word(text: "late after endpoint")], at: 101.7, reason: "punctuation")
    try await segment(room, words: [Word(text: "ordinary")], at: 103, reason: "punctuation")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await room.documentSnapshot.text == "Alex")
    #expect(await binder.hasUnsentInstruction, "Only the speech after the dismissal remains, as a general instruction")
    #expect(await events.values.filter { $0.channel == .hint }.isEmpty)
    #expect(await events.values.filter { $0.channel == .asrTail && $0.payload["text"] == .string("old partial") }.isEmpty)
    await binder.stop()
}

@Test func correctionDraftAccumulatesAcrossPauseAndOnlySendsAfterExplicitFlush() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "target", text: "Alex")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let binder = HintBinder(room: room, quietDelay: .seconds(60))
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: line.id, wordID: "target", timestamp: 100)
    try await room.publish(channel: .asrTail, participant: .transcriber,
                           payload: .object(["text": .string("Use Morgan"), "activity": .bool(true)]), tOrigin: 101)
    try await Task.sleep(for: .milliseconds(15))
    #expect(await events.values.last(where: { $0.channel == .correctionDraft })?.payload["text"] == .string("Use Morgan"))
    try await segment(room, words: [Word(text: "Use"), Word(text: "Morgan"), Word(text: "instead.")], at: 101, reason: "punctuation")
    try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("endpoint")]), tOrigin: 102)
    try await Task.sleep(for: .milliseconds(15))
    #expect(await events.values.filter { $0.channel == .hint }.isEmpty)
    #expect(await room.documentSnapshot.text == "Alex")
    #expect(await binder.requestSend(timestamp: 103))
    try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]), tOrigin: 104)
    let hint = try #require(await waitForHint(events))
    #expect(hint.payload["text"] == .string("Use Morgan instead."))
    #expect(!(await binder.requestSend(timestamp: 105)))
    try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]), tOrigin: 106)
    try await Task.sleep(for: .milliseconds(10))
    #expect(await events.values.filter { $0.channel == .hint }.count == 1)
    await binder.stop()
}

private actor SendCount {
    var count = 0
    func increment() { count += 1 }
}

@Test func correctionCountdownCancelsOnSpeechAndDismissalAndSendsOnce() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(id: "target", text: "Alex")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let count = SendCount()
    let binder = HintBinder(room: room, quietDelay: .milliseconds(40), countdown: .milliseconds(120), onSend: { await count.increment() })
    await binder.start()
    let events = HintEvents(), observation = await observeHints(room, events)
    defer { observation.cancel() }
    try await binder.tap(lineID: line.id, wordID: "target", timestamp: 100)
    func speech(_ activity: Bool = true) async throws {
        try await room.publish(channel: .asrTail, participant: .transcriber,
            payload: .object(["text": .string("Morgan"), "activity": .bool(activity)]), tOrigin: 101)
    }
    try await speech()
    try await Task.sleep(for: .milliseconds(70))
    let started = try #require(await events.values.last(where: { $0.channel == .correctionDraft }))
    #expect(started.payload["countdownDeadline"] != .null)
    try await speech()
    try await Task.sleep(for: .milliseconds(15))
    #expect(await events.values.last(where: { $0.channel == .correctionDraft })?.payload["countdownDeadline"] == .null)
    try await Task.sleep(for: .milliseconds(60))
    try await speech(false) // A non-speech tail publication must not restart the timer.
    try await Task.sleep(for: .milliseconds(100))
    #expect(await count.count == 1)
    #expect(await binder.requestSend(timestamp: 102)) // Same path used by the host callback.
    await binder.completeSend()
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await binder.requestSend(timestamp: 103)))
    try await binder.tap(lineID: line.id, wordID: "target", timestamp: 104)
    try await speech()
    await binder.clearSelection(timestamp: 105)
    try await Task.sleep(for: .milliseconds(190))
    #expect(await count.count == 1)
    #expect(await events.values.last(where: { $0.channel == .correctionDraft })?.payload["text"] == .null)
    await binder.stop()
}
