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

    await session.undo()
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
