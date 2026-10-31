import Testing
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAppServices

@MainActor @Test func onlyValidatedDictationAdvancesFollowScrollProgress() async throws {
    let room = Room(resumable: true)
    let session = ComposerSession(room: room)
    let stream = await room.subscribe(participant: .ui, channels: [.docOps, .docSnapshot], buffering: .unbounded)
    var events = stream.makeAsyncIterator()
    _ = try await room.appendSegment(words: [Word(text: "Spoken")])
    await session.receive(try #require(await events.next()))
    #expect(session.dictationRevision == 0) // Wait until the matching snapshot is visible.
    await session.receive(try #require(await events.next()))
    #expect(session.dictationRevision == 1)
    let line = try #require(session.snapshot.lines.first)
    _ = try await room.applyDocument([.replaceInLine(lineID: line.id, old: "Spoken", new: "Edited")], origin: .agent, versions: [line.id: line.version])
    await session.receive(try #require(await events.next()))
    await session.receive(try #require(await events.next()))
    #expect(session.snapshot.text == "Edited")
    #expect(session.dictationRevision == 1) // Rewrites must not steal the user's scroll position.
}
