import Foundation
import Testing
import LegatoComposerDoc
@testable import LegatoRoom

private actor InstructionEvents {
    var values: [Envelope] = []
    func add(_ event: Envelope) { values.append(event) }
}
private func observeInstructions(_ room: Room, _ events: InstructionEvents) async -> Task<Void, Never> {
    let stream = await room.subscribe(participant: .logger, channels: [.writingInstruction, .asrTail, .instructionDraft, .hint])
    return Task { for await event in stream { await events.add(event) } }
}
private func settleInstructionRouting() async throws { try await Task.sleep(for: .milliseconds(35)) }
private func inputSegment(_ room: Room, _ text: [String], origin: Double, times: [Double]? = nil) async throws {
    let metadata: JSONValue = .object([
        "t0": .number(times?.first ?? 0),
        "timings": .array((times ?? text.map { _ in 0 }).map { .object(["t0": .number($0), "t1": .number($0 + 0.2)]) }),
        "reason": .string("punctuation")])
    try await room.publish(channel: .asrSegment, participant: .segmenter,
        payload: .object(["words": try .encoding(text.map { Word(text: $0) }), "metadata": metadata]), tOrigin: origin)
}
private func inputBoundary(_ room: Room, at time: Double) async throws {
    try await room.publish(channel: .asrBoundary, participant: .segmenter,
        payload: .object(["reason": .string("endpoint")]), tOrigin: time)
}

@Test func instructionChunksNeverAppendAndCoalescePunctuationUntilBoundary() async throws {
    let room = Room(segmentRouting: .intercepted), binder: HintBinder
    _ = try await room.appendSegment(words: [.init(text: "Original draft")])
    binder = HintBinder(room: room)
    await binder.start(); await binder.setInputMode(.instructions, timestamp: 100)
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await room.publish(channel: .asrTail, participant: .transcriber,
        payload: .object(["text": .string("Make it concise"), "activity": .bool(true)]), tOrigin: 101)
    try await inputSegment(room, ["Make", "it", "concise."], origin: 102)
    try await inputSegment(room, ["Keep", "the", "facts."], origin: 103)
    try await settleInstructionRouting()
    #expect(await room.documentSnapshot.text == "Original draft")
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    #expect(await events.values.filter { $0.channel == .asrTail }.allSatisfy { $0.payload["text"] == .string("") })
    try await inputBoundary(room, at: 105)
    try await settleInstructionRouting()
    let instructions = await events.values.filter { $0.channel == .writingInstruction }
    #expect(instructions.count == 1)
    let event = try #require(instructions.first)
    #expect(event.payload["text"] == .string("Make it concise. Keep the facts."))
    #expect(try event.payload["snapshot"]?.decode(DocumentSnapshot.self).text == "Original draft")
    #expect(try event.payload["sources"]?.decode([JSONValue].self).count == 2)
    try await room.micOff()
    #expect(await room.state == .finalPass, "Instruction segments must be resolved after their single event")
    await binder.stop()
}

@Test func delayedFinalsAcrossTwoChannelFlipsKeepAcousticModeAndCapturePriorDictation() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start()
    await binder.setInputMode(.instructions, timestamp: 110)
    await binder.setInputMode(.dictation, timestamp: 120)
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    // All arrive after both UI taps; absolute audio times, not arrival time, determine the channel.
    try await inputSegment(room, ["Before", "Shorten", "After"], origin: 105, times: [5, 12, 22])
    try await inputBoundary(room, at: 125)
    try await settleInstructionRouting()
    #expect(await room.documentSnapshot.text == "Before\nAfter")
    let instruction = try #require(await events.values.first { $0.channel == .writingInstruction })
    #expect(instruction.payload["text"] == .string("Shorten"))
    #expect(try instruction.payload["snapshot"]?.decode(DocumentSnapshot.self).text == "Before")
    await binder.stop()
}

@Test func selectedQuoteOverridesInstructionsWithoutDuplicatingGlobalCommand() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    _ = try await room.appendSegment(words: [.init(id: "word", text: "wrong")])
    let line = try #require(await room.documentSnapshot.lines.first)
    await binder.start(); await binder.setInputMode(.instructions, timestamp: 100)
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await binder.select(lineID: line.id, wordID: "word", timestamp: 101)
    try await inputSegment(room, ["Use", "Morgan"], origin: 102)
    try await settleInstructionRouting()
    #expect(await binder.requestSend(timestamp: 103))
    await binder.completeSend()
    try await settleInstructionRouting()
    #expect(await room.documentSnapshot.text == "wrong")
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    #expect(await events.values.filter { $0.channel == .hint }.count == 1)
    await binder.stop()
}

@Test func emptyInstructionBoundaryDoesNotEmitAnInstruction() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start(); await binder.setInputMode(.instructions, timestamp: 100)
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputBoundary(room, at: 101)
    try await inputBoundary(room, at: 102)
    try await settleInstructionRouting()
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    #expect(await room.documentSnapshot.lines.isEmpty)
    await binder.stop()
}

@Test func untimedPendingSpeechKeepsItsLatchedChannelAcrossAFlip() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await room.publish(channel: .asrTail, participant: .transcriber,
        payload: .object(["text": .string("old dictation"), "activity": .bool(true)]), tOrigin: 100)
    try await settleInstructionRouting()
    await binder.setInputMode(.instructions, timestamp: 101)
    try await room.publish(channel: .asrSegment, participant: .segmenter,
        payload: .object(["words": try .encoding([Word(text: "old dictation")])]), tOrigin: 102)
    try await inputBoundary(room, at: 103)
    try await settleInstructionRouting()
    try await room.publish(channel: .asrTail, participant: .transcriber,
        payload: .object(["text": .string("shorten"), "activity": .bool(true)]), tOrigin: 104)
    try await settleInstructionRouting()
    await binder.setInputMode(.dictation, timestamp: 105)
    try await room.publish(channel: .asrSegment, participant: .segmenter,
        payload: .object(["words": try .encoding([Word(text: "shorten")])]), tOrigin: 106)
    try await inputBoundary(room, at: 107)
    try await settleInstructionRouting()
    #expect(await room.documentSnapshot.text == "old dictation")
    let instructions = await events.values.filter { $0.channel == .writingInstruction }
    #expect(instructions.count == 1)
    #expect(instructions.first?.payload["text"] == .string("shorten"))
    await binder.stop()
}
