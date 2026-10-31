import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
import LegatoComposerDoc
@testable import LegatoAgent

private actor ControlledSentenceCleaner: SentenceCleaning {
    var inputs: [SentenceCleanupInput] = []
    var continuations: [Int: CheckedContinuation<ValidatedSentence, any Error>] = [:]
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        inputs.append(input)
        return try await withCheckedThrowingContinuation { continuations[input.sequence] = $0 }
    }
    func complete(_ sequence: Int, text: String) {
        guard let input = inputs.last(where: { $0.sequence == sequence }) else { return }
        continuations.removeValue(forKey: sequence)?.resume(returning: .init(sentenceID: input.sentenceID, sequence: sequence, text: text))
    }
    func fail(_ sequence: Int) { continuations.removeValue(forKey: sequence)?.resume(throwing: SentenceCleanupError.providerError) }
    var count: Int { inputs.count }
}
private final class ValidatedWriterClient: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let viewFirst: Bool
    let insertInstruction: Bool
    init(viewFirst: Bool = false, insertInstruction: Bool = false) { self.viewFirst = viewFirst; self.insertInstruction = insertInstruction }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let count = requests.withLock { $0.append(request); return $0.count }
        let json = try! JSONDecoder().decode(JSONValue.self, from: request)
        let messages = (try? json["messages"]?.decode([JSONValue].self)) ?? []
        let current = messages.reversed().compactMap { if case .string(let text) = $0["content"], text.contains("Writing phase:") { return text }; return nil }.first ?? ""
        let tool: String? = viewFirst && count == 1 ? "view" : (insertInstruction && current.contains("Writing phase: instruction") ? "insert_draft" : nil)
        return AsyncThrowingStream { continuation in
            let block: JSONValue = tool.map { .object(["type": .string("tool_use"), "id": .string("tool-one"), "name": .string($0), "input": .object([:])]) }
                ?? .object(["type": .string("text"), "text": .string("Draft is suitable.")])
            let value: JSONValue = .object(["index": .number(0), "content_block": block])
            continuation.yield(.init(event: "content_block_start", data: String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)))
            continuation.yield(.init(event: "message_delta", data: #"{"usage":{"input_tokens":50001}}"#))
            continuation.finish()
        }
    }
}
private actor PipelineEvents {
    var values: [Envelope] = []
    func add(_ value: Envelope) { values.append(value) }
}
private func pipelineWait(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<200 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
    return false
}
private func pipelineFixture(room: Room, cleaner: ControlledSentenceCleaner) async -> (HintBinder, OrderedSentencePipeline) {
    // The box resolves the deliberate binder/pipeline cycle without copying raw speech into Room docs.
    let box = PipelineBox()
    let binder = HintBinder(room: room, onDictation: { sentence in await box.enqueue(sentence) })
    let pipeline = OrderedSentencePipeline(cleaner: cleaner, accept: { value in try await binder.acceptValidatedDictation(value) })
    await box.set(pipeline)
    await binder.start()
    return (binder, pipeline)
}
private actor PipelineBox {
    var pipeline: OrderedSentencePipeline?
    func set(_ value: OrderedSentencePipeline) { pipeline = value }
    func enqueue(_ sentence: DictationSentence) async { await pipeline?.enqueue(sentence) }
}

@Test func sentencesValidateInParallelButAppendInOrderWithoutClobberingWriterEdits() async throws {
    let room = Room(segmentRouting: .intercepted, validateDictation: true), cleaner = ControlledSentenceCleaner()
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    _ = try await room.publishSegment(words: [.init(text: "RAW_ZERO.")])
    _ = try await room.publishSegment(words: [.init(text: "RAW_ONE.")])
    _ = try await room.publishSegment(words: [.init(text: "RAW_TWO.")])
    #expect(await pipelineWait { await cleaner.count == 2 }, "Only two sentence requests may run concurrently")
    await cleaner.complete(1, text: "Second cleaned sentence.")
    #expect(await room.documentSnapshot.lines.isEmpty)
    await cleaner.complete(0, text: "First cleaned sentence.")
    #expect(await pipelineWait { await room.documentSnapshot.lines.count == 2 })
    let first = try #require(await room.documentSnapshot.lines.first)
    _ = try await room.applyDocument([.replaceInLine(lineID: first.id, old: "First", new: "Authored")], origin: .agent, versions: [first.id: first.version])
    #expect(await pipelineWait { await cleaner.count == 3 })
    await cleaner.complete(2, text: "Third cleaned sentence.")
    #expect(await pipelineWait { await room.documentSnapshot.lines.count == 3 })
    #expect(await room.documentSnapshot.lines.map(\.text) == ["Authored cleaned sentence.", "Second cleaned sentence.", "Third cleaned sentence."])
    await pipeline.cancel(); await binder.stop()
}

@Test func failedSentenceKeepsRawPendingAndPauseWaitsForExplicitRetryWithoutFallback() async throws {
    let room = Room(segmentRouting: .intercepted, resumable: true, validateDictation: true, drainOnly: true), cleaner = ControlledSentenceCleaner()
    let events = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded), captured = PipelineEvents()
    let collect = Task { for await event in events { await captured.add(event) } }
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    _ = try await room.publishSegment(words: [.init(text: "PENDING_RAW_ONLY.")])
    #expect(await pipelineWait { await cleaner.count == 1 })
    await cleaner.fail(0)
    #expect(await pipelineWait { await pipeline.hasFailure })
    try await room.micOff()
    #expect(await room.state == .trailing)
    #expect(await room.documentSnapshot.lines.isEmpty)
    #expect(await pipelineWait { await captured.values.contains { $0.payload["text"] == .string("PENDING_RAW_ONLY.") } })
    await pipeline.retryFailed()
    #expect(await pipelineWait { await cleaner.count == 2 })
    await cleaner.complete(0, text: "Validated sentence.")
    #expect(await pipelineWait { await room.state == .finalPass })
    #expect(await room.documentSnapshot.text == "Validated sentence.")
    try await room.finishFinalPass()
    #expect(await room.state == .paused)
    collect.cancel(); await pipeline.cancel(); await binder.stop()
}

@Test func writerNeverSeesRawSentencesAndPauseAddsNoAutomaticPolishingRequest() async throws {
    let room = Room(segmentRouting: .intercepted, resumable: true, validateDictation: true, drainOnly: true), cleaner = ControlledSentenceCleaner()
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    let client = ValidatedWriterClient()
    let writer = AgentRunner(room: room, client: client, configuration: .init(validatedSentenceInput: true), pauseDelay: .milliseconds(30))
    await writer.start()
    _ = try await room.publishSegment(words: [.init(text: "NEVER_RAW_SECRET.", alternatives: ["NEVER_RAW_ALTERNATIVE"])])
    #expect(await pipelineWait { await cleaner.count == 1 })
    _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("NEVER_RAW_PARTIAL"), "activity": .bool(true)]))
    try await Task.sleep(for: .milliseconds(70))
    #expect(client.requests.withLock { $0.isEmpty }, "Raw-partial quiet clocks must not start an empty author request before validation")
    try await room.micOff()
    await cleaner.complete(0, text: "Cleaned first sentence.")
    #expect(await pipelineWait { await room.state == .paused })
    #expect(client.requests.withLock { $0.count } == 1)
    #expect(client.requests.withLock { $0.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("NEVER_RAW_SECRET") } })
    try await room.resume()
    _ = try await room.publish(channel: .session, participant: .transcriber, payload: .object(["event": .string("raw.future.diagnostic"), "text": .string("NEVER_RAW_SECRET")]))
    _ = try await room.publishSegment(words: [.init(text: "NEVER_RAW_SECOND.")])
    #expect(await pipelineWait { await cleaner.count == 2 })
    await cleaner.complete(1, text: "Cleaned continuation.")
    #expect(await pipelineWait { client.requests.withLock { $0.count } == 2 })
    try await room.micOff()
    #expect(await pipelineWait { await room.state == .paused })
    #expect(client.requests.withLock { $0.count } == 2)
    #expect(client.requests.withLock { $0.allSatisfy { let text = String(decoding: $0, as: UTF8.self); return !text.contains("NEVER_RAW_SECRET") && !text.contains("NEVER_RAW_ALTERNATIVE") && !text.contains("NEVER_RAW_SECOND") && !text.contains("Writing phase: final") } })
    await writer.stop(); await pipeline.cancel(); await binder.stop()
}

@Test func timedInstructionBypassesCleanerAndWaitsForPriorValidatedDictationOnly() async throws {
    let room = Room(segmentRouting: .intercepted, validateDictation: true), cleaner = ControlledSentenceCleaner()
    let events = await room.subscribe(participant: .ui, channels: [.writingInstruction], buffering: .unbounded), captured = PipelineEvents()
    let collect = Task { for await event in events { await captured.add(event) } }
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    await binder.setInputMode(.instructions, timestamp: 2)
    await binder.setInputMode(.dictation, timestamp: 3)
    _ = try await room.publish(channel: .asrSegment, participant: .segmenter, payload: .object([
        "words": try .encoding([Word(text: "RAW_BEFORE"), Word(text: "Rewrite"), Word(text: "RAW_AFTER")]),
        "metadata": .object(["t0": .number(1), "timings": .array([1.0, 2, 3].map { .object(["t0": .number($0), "t1": .number($0 + 0.2)]) })])]), tOrigin: 1)
    _ = try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("finalize")]), tOrigin: 4)
    #expect(await pipelineWait { await cleaner.count == 2 })
    #expect(await cleaner.inputs.map(\.text) == ["RAW_BEFORE", "RAW_AFTER"])
    #expect(await captured.values.isEmpty)
    await cleaner.complete(0, text: "Validated before.")
    #expect(await pipelineWait { await captured.values.count == 1 })
    let instruction = try #require(await captured.values.first)
    #expect(instruction.payload["text"] == .string("Rewrite"))
    #expect(try instruction.payload["snapshot"]?.decode(DocumentSnapshot.self).text == "Validated before.")
    await cleaner.complete(1, text: "Validated after.")
    #expect(await pipelineWait { await room.documentSnapshot.lines.count == 2 })
    collect.cancel(); await pipeline.cancel(); await binder.stop()
}

@Test func canceledPipelineRejectsLateCleanupAndPreservesUnchangedWordIdentity() async throws {
    let cleaner = ControlledSentenceCleaner(), accepted = Mutex<[ValidatedDictation]>([])
    let pipeline = OrderedSentencePipeline(cleaner: cleaner, accept: { value in accepted.withLock { $0.append(value) } })
    let source = [Word(id: "word-one", text: "Café", confidence: 0.72, language: "fr", alternatives: ["Cafe"]), Word(id: "word-two", text: "hello", confidence: 0.4)]
    let mapped = OrderedSentencePipeline.validatedWords("Café hello! 👩🏽‍💻", source: source)
    #expect(mapped[0] == source[0])
    #expect(mapped[1].id != "word-two")
    #expect(mapped[1].confidence == nil)
    #expect(mapped[2].text == "👩🏽‍💻")
    await pipeline.enqueue(.init(sequence: 0, sourceSegmentID: "raw", words: source, origin: 0))
    #expect(await pipelineWait { await cleaner.count == 1 })
    await pipeline.cancel()
    await cleaner.complete(0, text: "Café hello!")
    try await Task.sleep(for: .milliseconds(30))
    #expect(accepted.withLock { $0.isEmpty })
    #expect(await pipeline.pendingCount == 0)
}

@Test func shortAcousticGapsAndTransportCapsDoNotSplitAnUnfinishedSentence() async throws {
    let room = Room(segmentRouting: .intercepted, validateDictation: true), cleaner = ControlledSentenceCleaner()
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    _ = try await room.publishSegment(words: [.init(text: "Please investigate why")])
    _ = try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("gap")]))
    _ = try await room.publish(channel: .asrBoundary, participant: .segmenter, payload: .object(["reason": .string("endpoint")]))
    try await Task.sleep(for: .milliseconds(30))
    #expect(await cleaner.count == 0)
    #expect(await room.documentSnapshot.lines.isEmpty)
    _ = try await room.publishSegment(words: [.init(text: "the keyboard disappears.")])
    #expect(await pipelineWait { await cleaner.count == 1 })
    #expect(await cleaner.inputs.first?.text == "Please investigate why the keyboard disappears.")
    await cleaner.complete(0, text: "Please investigate why the keyboard disappears.")
    #expect(await pipelineWait { await room.documentSnapshot.lines.count == 1 })
    // The provider's 25-word/8-second chunks are transport units, not new lines.
    for index in 0..<3 { _ = try await room.publishSegment(words: (0..<12).map { Word(text: "word\(index)-\($0)") }) }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await cleaner.count == 1)
    _ = try await room.publishSegment(words: [.init(text: "finishes.")])
    #expect(await pipelineWait { await cleaner.count == 2 })
    #expect(await cleaner.inputs.last?.text.split(whereSeparator: \.isWhitespace).count == 37)
    await cleaner.complete(1, text: "The long sentence finishes.")
    #expect(await pipelineWait { await room.documentSnapshot.lines.count == 2 })
    await pipeline.cancel(); await binder.stop()
}

@Test func acousticAlternativesStayPrivateAcrossAuthorViewAndHistoryReseed() async throws {
    let room = Room(segmentRouting: .intercepted, resumable: true, validateDictation: true, drainOnly: true), cleaner = ControlledSentenceCleaner()
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    let client = ValidatedWriterClient(viewFirst: true)
    let writer = AgentRunner(room: room, client: client, configuration: .init(validatedSentenceInput: true), pauseDelay: .seconds(100))
    await writer.start()
    _ = try await room.publishSegment(words: [.init(id: "stable-word", text: "Validated.", confidence: 0.9, alternatives: ["PRIVATE_RAW_VARIANT"])])
    #expect(await pipelineWait { await cleaner.count == 1 })
    await cleaner.complete(0, text: "Validated.")
    #expect(await pipelineWait { client.requests.withLock { $0.count } == 2 })
    #expect(await room.documentSnapshot.lines.first?.words.first?.alternatives == ["PRIVATE_RAW_VARIANT"], "UI keeps source alternatives without exposing them to the author")
    _ = try await room.publishSegment(words: [.init(text: "Next.")])
    #expect(await pipelineWait { await cleaner.count == 2 })
    await cleaner.complete(1, text: "Next.")
    #expect(await pipelineWait { client.requests.withLock { $0.count } == 3 })
    #expect(client.requests.withLock { $0.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("PRIVATE_RAW_VARIANT") } })
    try await room.micOff()
    #expect(await pipelineWait { await room.state == .paused })
    #expect(client.requests.withLock { $0.count } == 3)
    await writer.stop(); await pipeline.cancel(); await binder.stop()
}

private actor PipelineLatch {
    var opened = false
    func open() { opened = true }
    func wait() async { while !opened { try? await Task.sleep(for: .milliseconds(5)) } }
}
@Test func hostInsertDrainsLateValidatedAuthoringWithoutAFinalRewriteOrSelfDeadlock() async throws {
    let room = Room(segmentRouting: .intercepted, resumable: true, validateDictation: true, drainOnly: true), cleaner = ControlledSentenceCleaner()
    _ = try await room.applyDocument([.insertLines(after: nil, lines: [Line(words: [Word(text: "Existing draft.")])])], origin: .user, versions: [:])
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    let client = ValidatedWriterClient(insertInstruction: true), latch = PipelineLatch()
    let actions = Mutex(0), result = Mutex(false)
    let writer = AgentRunner(room: room, client: client, configuration: .init(validatedSentenceInput: true,
        hostActionContext: { .init(sessionToken: "current-session", targetToken: "bound-field") },
        performHostAction: { _ in
            actions.withLock { $0 += 1 }
            await latch.wait()
            try? await room.micOff()
            let drained = await pipelineWait { await room.state == .paused }
            result.withLock { $0 = drained }
            return .init(succeeded: drained, message: drained ? "Inserted" : "Drain failed")
        }), pauseDelay: .seconds(100))
    await writer.start()
    _ = try await room.publish(channel: .writingInstruction, participant: .hintBinder, payload: .object([
        "event": .string("global.instruction"), "captureID": .string("insert-once"), "text": .string("Insert the draft"), "snapshot": try .encoding(await room.documentSnapshot)]))
    #expect(await pipelineWait { actions.withLock { $0 } == 1 })
    _ = try await room.publishSegment(words: [.init(text: "RAW_LATE_SENTENCE.")])
    #expect(await pipelineWait { await cleaner.count == 1 })
    await latch.open()
    await cleaner.complete(0, text: "Validated late sentence.")
    #expect(await pipelineWait { result.withLock { $0 } })
    #expect(client.requests.withLock { $0.count } == 2, "One explicit instruction plus one already-triggered authoring request, no polishing request")
    #expect(client.requests.withLock { $0.allSatisfy { !String(decoding: $0, as: UTF8.self).contains("RAW_LATE_SENTENCE") } })
    #expect(actions.withLock { $0 } == 1)
    await writer.stop(); await pipeline.cancel(); await binder.stop()
}

@Test func sentencePipelineBackpressureBoundsRetainedWorkWithoutDroppingAUnit() async throws {
    let cleaner = ControlledSentenceCleaner(), accepted = Mutex<[Int]>([])
    let pipeline = OrderedSentencePipeline(cleaner: cleaner, capacity: 2, accept: { value in accepted.withLock { $0.append(value.sequence) } })
    await pipeline.enqueue(.init(sequence: 0, sourceSegmentID: "zero", words: [Word(text: "Zero.")], origin: 0))
    await pipeline.enqueue(.init(sequence: 1, sourceSegmentID: "one", words: [Word(text: "One.")], origin: 1))
    let third = Task { await pipeline.enqueue(.init(sequence: 2, sourceSegmentID: "two", words: [Word(text: "Two.")], origin: 2)) }
    #expect(await pipelineWait { await cleaner.count == 2 })
    #expect(await pipeline.pendingCount == 2)
    await cleaner.complete(0, text: "Zero.")
    #expect(await pipelineWait { await cleaner.count == 3 })
    await cleaner.complete(2, text: "Two.")
    await cleaner.complete(1, text: "One.")
    #expect(await pipelineWait { accepted.withLock { $0 } == [0, 1, 2] })
    await third.value; await pipeline.cancel()
}

@Test func boundedLongSpeechMarksTheFollowingUnitAsContinuationNotANewParagraph() async throws {
    let room = Room(segmentRouting: .intercepted, validateDictation: true), cleaner = ControlledSentenceCleaner()
    let events = await room.subscribe(participant: .ui, channels: [.validatedSentence], buffering: .unbounded), captured = PipelineEvents()
    let collect = Task { for await event in events { await captured.add(event) } }
    let (binder, pipeline) = await pipelineFixture(room: room, cleaner: cleaner)
    _ = try await room.publishSegment(words: (0..<120).map { Word(text: "word\($0)") })
    #expect(await pipelineWait { await cleaner.count == 1 })
    _ = try await room.publishSegment(words: [Word(text: "ends.")])
    #expect(await pipelineWait { await cleaner.count == 2 })
    await cleaner.complete(0, text: "A long bounded thought")
    await cleaner.complete(1, text: "ends.")
    #expect(await pipelineWait { await captured.values.count == 2 })
    #expect(await captured.values.map { $0.payload["continuation"] } == [.bool(false), .bool(true)])
    collect.cancel(); await pipeline.cancel(); await binder.stop()
}
