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
