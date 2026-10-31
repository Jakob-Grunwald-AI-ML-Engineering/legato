import Foundation
import Testing
import LegatoComposerDoc
@testable import LegatoAppServices

@MainActor @Test func seededVisualEditUsesAgentTransactionAndOneUndo() async throws {
    let session = ComposerSession()
    try await session.seedDebugDraft("Keep ths sentence")
    let before = session.snapshot
    let line = try #require(before.lines.first)
    let ops = [DocOp.replaceInLine(lineID: line.id, old: "ths", new: "this")]
    _ = try await session.debugControl("composer-debug-edit", args: [String(decoding: JSONEncoder().encode(ops), as: UTF8.self)])
    #expect(session.snapshot.text == "Keep this sentence")
    #expect(session.snapshot.lines[0].words[0] == line.words[0])
    #expect(session.snapshot.lines[0].words[2] == line.words[2])
    #expect(session.snapshot.revision == before.revision + 1)
    #expect(!session.isListening && !session.isArmed)
    _ = try await session.debugControl("composer-undo", args: [])
    #expect(session.snapshot.lines[0].words == line.words)
}

@MainActor @Test func visualEditCannotModifyAnUnseededSession() async {
    let session = ComposerSession()
    do {
        try await session.applyDebugDocumentEdits("[]")
        Issue.record("Visual edit should require an explicitly seeded fixture")
    } catch {
        #expect(session.snapshot.lines.isEmpty)
        #expect(!session.isListening && !session.isArmed)
    }
}
