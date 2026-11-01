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

/// The Send path the host runs: request, drain the provider, then the finalize boundary publishes once.
private func sendInstruction(_ binder: HintBinder) async throws {
    try await settleInstructionRouting()
    #expect(await binder.requestInstructionSend())
    await binder.completeInstructionSend()
}

@Test func speechAccumulatesAcrossBoundariesIntoOneInstructionSentOnDemandAndNeverTouchesTheDraft() async throws {
    let room = Room(segmentRouting: .intercepted), binder: HintBinder
    _ = try await room.appendSegment(words: [.init(text: "Original draft")])
    binder = HintBinder(room: room)
    await binder.start()
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
    #expect(await events.values.last { $0.channel == .instructionDraft }?.payload["text"] == .string("Make it concise. Keep the facts."))
    try await inputBoundary(room, at: 105)
    try await settleInstructionRouting()
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty, "A segment boundary never sends")
    #expect(await events.values.last { $0.channel == .instructionDraft }?.payload["text"] == .string("Make it concise. Keep the facts."))
    try await sendInstruction(binder)
    try await settleInstructionRouting()
    let instructions = await events.values.filter { $0.channel == .writingInstruction }
    #expect(instructions.count == 1)
    let event = try #require(instructions.first)
    #expect(event.payload["text"] == .string("Make it concise. Keep the facts."))
    #expect(try event.payload["snapshot"]?.decode(DocumentSnapshot.self).text == "Original draft")
    #expect(try event.payload["sources"]?.decode([JSONValue].self).count == 2)
    #expect(await events.values.last { $0.channel == .instructionDraft }?.payload["text"] == .string(""))
    try await room.micOff()
    #expect(await room.state == .finalPass, "Instruction segments must be resolved after their single event")
    await binder.stop()
}

@Test func contentRequestsOnAnEmptyDraftAreInstructionsToo() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputSegment(room, ["Write", "a", "short", "email", "to", "Anna", "saying", "I'm", "late."], origin: 101)
    try await sendInstruction(binder)
    try await settleInstructionRouting()
    #expect(await room.documentSnapshot.lines.isEmpty, "Speech is never dictated into the draft")
    let instruction = try #require(await events.values.first { $0.channel == .writingInstruction })
    #expect(instruction.payload["text"] == .string("Write a short email to Anna saying I'm late."))
    #expect(try instruction.payload["snapshot"]?.decode(DocumentSnapshot.self).lines.isEmpty == true)
    await binder.stop()
}

@Test func separatelySentInstructionsAreSeparateAndTheSnapshotIsTakenWhenSent() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputSegment(room, ["Write", "a", "greeting."], origin: 101)
    // The writer's edit lands while the user is still speaking the next instruction.
    _ = try await room.applyDocument([.insertLines(after: nil, lines: [Line(words: [Word(text: "Hello")])])], origin: .agent, versions: [:])
    try await sendInstruction(binder)
    try await inputSegment(room, ["Make", "it", "warmer."], origin: 103)
    try await sendInstruction(binder)
    try await settleInstructionRouting()
    let sent = await events.values.filter { $0.channel == .writingInstruction }
    #expect(sent.map { $0.payload["text"] } == [.string("Write a greeting."), .string("Make it warmer.")])
    #expect(try sent.last?.payload["snapshot"]?.decode(DocumentSnapshot.self).text == "Hello")
    await binder.stop()
}

private actor SendCounter {
    var count = 0
    func increment() { count += 1 }
}
private func tail(_ room: Room, _ text: String, activity: Bool = true) async throws {
    try await room.publish(channel: .asrTail, participant: .transcriber,
        payload: .object(["text": .string(text), "activity": .bool(activity)]), tOrigin: 101)
}

@Test func manualModeNeverSendsOnItsOwn() async throws {
    let room = Room(segmentRouting: .intercepted), counter = SendCounter()
    let binder = HintBinder(room: room, instructionSendDelay: { nil }, onInstructionSend: { await counter.increment() })
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputSegment(room, ["Make", "it"], origin: 101)
    try await inputBoundary(room, at: 102)
    try await inputSegment(room, ["shorter."], origin: 103)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await counter.count == 0)
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    let draft = try #require(await events.values.last { $0.channel == .instructionDraft })
    #expect(draft.payload["text"] == .string("Make it shorter.") && draft.payload["countdownDeadline"] == .null)
    await binder.stop()
}

@Test func automaticModeSendsOnceAfterTheQuietDelayAndSpeechResetsIt() async throws {
    let room = Room(segmentRouting: .intercepted), counter = SendCounter(), clock = VirtualClock()
    let box = BinderBox()
    let binder = HintBinder(room: room, instructionSendDelay: { 0.25 }, onInstructionSend: {
        await counter.increment()
        if let binder = await box.binder { try? await sendInstruction(binder) }
    }, clock: clock)
    await box.set(binder)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    /// Waits until the binder published `text` with the countdown armed and exactly one quiet timer pending.
    func countdownArmed(for text: String) async {
        await eventually("countdown for \(text)") {
            let draft = await events.values.last { $0.channel == .instructionDraft }
            return clock.sleeperCount == 1 && draft?.payload["text"] == .string(text) && draft?.payload["countdownDeadline"] != .null
        }
    }
    try await inputSegment(room, ["Make", "it"], origin: 101)
    await countdownArmed(for: "Make it") // The countdown is published for the rim.
    clock.advance(by: .milliseconds(150))
    try await tail(room, "shorter") // resumed speech
    await countdownArmed(for: "Make it shorter")
    clock.advance(by: .milliseconds(150))
    #expect(await counter.count == 0, "Speech restarted the wait")
    try await inputSegment(room, ["shorter."], origin: 102)
    await countdownArmed(for: "Make it shorter.")
    clock.advance(by: .milliseconds(249))
    #expect(await counter.count == 0)
    clock.advance(by: .milliseconds(1))
    await eventually("instruction sent") { await events.values.filter { $0.channel == .writingInstruction }.count == 1 }
    #expect(await counter.count == 1)
    let sent = await events.values.filter { $0.channel == .writingInstruction }
    #expect(sent.count == 1 && sent.first?.payload["text"] == .string("Make it shorter."))
    await eventually("countdown cleared") { await events.values.last { $0.channel == .instructionDraft }?.payload["countdownDeadline"] == .null }
    await binder.stop()
}

private actor BinderBox {
    var binder: HintBinder?
    func set(_ value: HintBinder) { binder = value }
}

@Test func pausingListeningKeepsThePendingInstruction() async throws {
    let room = Room(segmentRouting: .intercepted, resumable: true)
    let binder = HintBinder(room: room)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputSegment(room, ["Make", "it"], origin: 101)
    try await settleInstructionRouting()
    try await room.micOff(); try await inputBoundary(room, at: 102)
    try await room.finishFinalPass()
    #expect(await room.state == .paused, "An unsent instruction does not hold the pause open")
    try await settleInstructionRouting()
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    #expect(await binder.hasUnsentInstruction)
    try await room.resume()
    try await inputSegment(room, ["shorter."], origin: 103)
    try await sendInstruction(binder)
    try await settleInstructionRouting()
    let sent = await events.values.filter { $0.channel == .writingInstruction }
    #expect(sent.count == 1 && sent.first?.payload["text"] == .string("Make it shorter."))
    await binder.stop()
}

@Test func liveTailOutsideAQuoteIsTheInstructionDraftNotDraftText() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await room.publish(channel: .asrTail, participant: .transcriber,
        payload: .object(["text": .string("make it shor"), "activity": .bool(true)]), tOrigin: 100)
    try await settleInstructionRouting()
    #expect(await events.values.last { $0.channel == .instructionDraft }?.payload["text"] == .string("make it shor"))
    #expect(await events.values.filter { $0.channel == .asrTail }.allSatisfy { $0.payload["text"] == .string("") })
    await binder.stop()
}

@Test func selectedQuoteOverridesInstructionsWithoutDuplicatingGlobalCommand() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    _ = try await room.appendSegment(words: [.init(id: "word", text: "wrong")])
    let line = try #require(await room.documentSnapshot.lines.first)
    await binder.start()
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
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputBoundary(room, at: 101)
    try await inputBoundary(room, at: 102)
    try await settleInstructionRouting()
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    #expect(await room.documentSnapshot.lines.isEmpty)
    await binder.stop()
}

@Test func discardedInstructionDropsItsWordsIncludingLateFinals() async throws {
    let room = Room(segmentRouting: .intercepted), binder = HintBinder(room: room)
    await binder.start()
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputSegment(room, ["Make", "it"], origin: 101)
    try await settleInstructionRouting()
    #expect(await binder.hasUnsentInstruction)
    await binder.discardInstruction(timestamp: 110)
    try await inputSegment(room, ["Late"], origin: 109)
    try await inputBoundary(room, at: 111)
    try await settleInstructionRouting()
    #expect(!(await binder.hasUnsentInstruction))
    #expect(await events.values.filter { $0.channel == .writingInstruction }.isEmpty)
    #expect(await room.documentSnapshot.lines.isEmpty)
    await binder.stop()
}

@Test func manualQuoteWaitsForWandAndDoesNotHoldPauseOpen() async throws {
    let room = Room(segmentRouting: .intercepted, resumable: true)
    _ = try await room.appendSegment(words: [.init(text: "Original")])
    let binder = HintBinder(room: room, quietDelay: .milliseconds(5), countdown: .milliseconds(5), requiresExplicitSubmission: true)
    await binder.start()
    let line = try #require(await room.documentSnapshot.lines.first)
    try await binder.select(lineID: line.id, wordID: line.words[0].id, timestamp: 100)
    let events = InstructionEvents(), observer = await observeInstructions(room, events)
    defer { observer.cancel() }
    try await inputSegment(room, ["Use", "better", "wording"], origin: 101)
    try await inputBoundary(room, at: 103)
    try await settleInstructionRouting()
    #expect(await events.values.filter { $0.channel == .hint }.isEmpty)
    try await room.micOff(); try await room.finishFinalPass()
    #expect(await room.state == .paused)
    #expect(await binder.requestSend(timestamp: 105))
    #expect(!(await binder.requestSend(timestamp: 105)))
    await binder.completeSend(); await binder.completeSend()
    try await settleInstructionRouting()
    #expect(await events.values.filter { $0.channel == .hint }.count == 1)
    #expect(await room.documentSnapshot.text == "Original")
    await binder.stop()
}
