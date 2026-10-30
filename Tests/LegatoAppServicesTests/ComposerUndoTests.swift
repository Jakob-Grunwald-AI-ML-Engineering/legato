import Testing
@testable import LegatoAppServices
import LegatoComposerDoc
import LegatoRoom

@MainActor @Test func repeatedComposerUndoDoesNotRedoItsInverse() async throws {
    let room = Room()
    let events = await room.subscribe(participant: .ui, channels: [.docOps], buffering: .unbounded)
    var iterator = events.makeAsyncIterator()
    let session = ComposerSession(room: room)
    _ = try await room.appendSegment(words: [.init(text: "Morgan")])
    await session.receive(try #require(await iterator.next()))
    let original = await room.documentSnapshot
    let line = try #require(original.lines.first)
    _ = try await room.applyDocument([.pinWord(lineID: line.id, wordID: line.words[0].id, text: "Morgan,")], origin: .user, versions: [line.id: line.version])
    await session.receive(try #require(await iterator.next()))

    #expect(session.canUndo)
    await session.undo()
    #expect(!session.canUndo)
    await session.receive(try #require(await iterator.next()))
    let undone = await room.documentSnapshot
    #expect(undone.lines.first?.text == "Morgan")
    await session.undo()
    let repeated = await room.documentSnapshot
    #expect(repeated == undone, "A second Undo must not invert the first Undo and restore the comma")
    #expect(session.error == nil)
}

@MainActor @Test func completedComposerClearsActivityAndKeepsInsertableText() async throws {
    let room = Room()
    let events = await room.subscribe(participant: .ui, channels: [.session, .docSnapshot], buffering: .unbounded)
    let session = ComposerSession(room: room)
    _ = try await room.appendSegment(words: [.init(text: "Ready to insert")])
    await session.receive(try await room.publish(channel: .agentStatus, participant: .liveAgent, payload: .object(["busy": .bool(true)])))
    await session.receive(try await room.publish(channel: .agentStatus, participant: .liveAgent, payload: .object(["event": .string("pending.edit"), "lines": .array([.string("pending-line")])])))
    #expect(session.busy)
    #expect(session.pendingLineIDs == ["pending-line"])

    try await room.cancel()
    for await event in events { await session.receive(event) }

    #expect(session.status == "done")
    #expect(!session.busy, "Terminal Room events must clear the spinner without a final agent busy=false event")
    #expect(session.pendingLineIDs.isEmpty)
    #expect(session.renderedText == "Ready to insert")
    #expect(session.error == nil)
}

@MainActor @Test func composerMuteKeepsAgentWorkAndRoomAliveThenResetsOnCancel() async throws {
    let room = Room()
    let session = ComposerSession(room: room)
    await session.receive(try await room.publish(channel: .session, participant: .ui, payload: .object(["state": .string("listening")])))
    await session.receive(try await room.publish(channel: .agentStatus, participant: .liveAgent, payload: .object(["busy": .bool(true)])))
    await session.setMuted(true)
    #expect(session.isMuted)
    #expect(session.isListening)
    #expect(session.busy, "Muting cannot cancel the pending agent work")
    #expect(await room.state == .listening)
    await session.setMuted(true)
    await session.setMuted(false)
    #expect(!session.isMuted)
    #expect(await room.state == .listening)
    await session.setMuted(true)
    await session.cancel()
    #expect(!session.isMuted)
    #expect(session.status == "idle")
}

@MainActor @Test func composerCancelClearsDraftAndDoesNotRestoreCancelledRoom() async throws {
    let room = Room()
    let session = ComposerSession(room: room)
    _ = try await room.appendSegment(words: [.init(text: "Discard this draft")])
    await session.refreshDebugState()
    await session.receive(try await room.publish(channel: .asrTail, participant: .ui, payload: .object(["text": .string("unfinished speech")])))
    await session.receive(try await room.publish(channel: .agentStatus, participant: .liveAgent, payload: .object(["busy": .bool(true), "event": .string("error"), "message": .string("Previous failure")])))
    await session.receive(try await room.publish(channel: .agentStatus, participant: .liveAgent, payload: .object(["event": .string("pending.edit"), "lines": .array([.string("pending-line")])])))
    await session.receive(try await room.publish(channel: .correctionDraft, participant: .ui, payload: .object(["text": .string("replace this"), "countdownStart": .number(1), "countdownDeadline": .number(2)])))
    #expect(!session.renderedText.isEmpty)
    #expect(session.busy)
    #expect(session.error != nil)

    await session.cancel()
    await session.refreshDebugState()

    #expect(session.snapshot.lines.isEmpty)
    #expect(session.renderedText.isEmpty)
    #expect(session.tail.isEmpty)
    #expect(session.hunks.isEmpty)
    #expect(session.status == "idle")
    #expect(session.sessionID == nil)
    #expect(session.audioOrigin == nil)
    #expect(session.error == nil)
    #expect(!session.busy)
    #expect(session.pendingLineIDs.isEmpty)
    #expect(!session.canUndo)
    #expect(session.correctionDraft == nil)
    #expect(session.correctionCountdownStart == nil)
    #expect(session.correctionCountdownDeadline == nil)
    // Repeated cancellation is safe before the next Start.
    await session.cancel()
    #expect(session.status == "idle")
    #expect(session.renderedText.isEmpty)
}
