import Foundation

import Testing
@testable import LegatoComposerDoc

private func seeded() throws -> ComposerDocument {
    var doc = ComposerDocument()
    try doc.appendSegment(words: [Word(id: "w1", text: "hello", confidence: 0.42, alternatives: ["hallo"]), Word(id: "w2", text: "world", confidence: 0.9)])
    return doc
}

@Test func rewritePreservesNeighboursAndClearsNewConfidence() throws {
    var doc = try seeded(); let line = doc.lines[0]
    let txn = try doc.apply([.replaceInLine(lineID: line.id, old: "world", new: "friend")], origin: .agent, versions: [line.id: line.version])
    #expect(doc.lines[0].words[0] == line.words[0])
    #expect(doc.lines[0].words[1].confidence == nil)
    #expect(doc.lines[0].words[1].id != "w2")
    #expect(txn.hunks == [.wordsReplaced(lineID: line.id, old: line.words, new: doc.lines[0].words)])
}
@Test func inverseRoundTripAndRawLane() throws {
    var doc = try seeded(); let before = doc.snapshot; let raw = doc.rawTranscript
    let txn = try doc.apply([.replaceInLine(lineID: before.lines[0].id, old: "world", new: "friend")], origin: .agent, versions: [before.lines[0].id: 0], groupID: "turn")
    try doc.apply(txn.inverse, origin: .undo, versions: [before.lines[0].id: 1])
    #expect(doc.lines[0].words == before.lines[0].words)
    #expect(doc.rawTranscript == raw)
    #expect(txn.groupID == "turn")
}
@Test func onlyTouchedVersionsMatterAndFailedBatchIsAtomic() throws {
    var doc = try seeded(); let first = doc.lines[0]
    try doc.appendSegment(words: [Word(text: "second")]); let second = doc.lines[1]
    try doc.apply([.setKind(ids: [second.id], kind: .li)], origin: .agent, versions: [second.id: 0])
    try doc.apply([.setKind(ids: [first.id], kind: .h1)], origin: .agent, versions: [first.id: 0, second.id: 0])
    let before = doc.snapshot
    #expect(throws: DocumentError.versionConflict(first.id)) {
        try doc.apply([.setKind(ids: [first.id], kind: .p)], origin: .agent, versions: [first.id: 0])
    }
    #expect(doc.snapshot == before)
}
@Test func pinnedWordsRejectAgentChangesIncludingDeletion() throws {
    var doc = try seeded(); let id = doc.lines[0].id
    try doc.apply([.pinWord(lineID: id, wordID: "w1", text: "Hallo")], origin: .user, versions: [id: 0])
    #expect(doc.lines[0].words[0].pinned)
    #expect(throws: DocumentError.pinnedWord("w1")) { try doc.apply([.replaceInLine(lineID: id, old: "Hallo", new: "Hello")], origin: .agent, versions: [id: 1]) }
    #expect(throws: DocumentError.pinnedWord("w1")) { try doc.apply([.deleteLines(ids: [id])], origin: .agent, versions: [id: 1]) }
}
@Test func insertMoveDeleteKeepIDsAndProduceHunks() throws {
    var doc = try seeded(); let first = doc.lines[0]
    let second = Line(id: "L2", words: [Word(id: "w3", text: "second")])
    let insert = try doc.apply([.insertLines(after: first.id, lines: [second])], origin: .agent, versions: [:])
    #expect(insert.hunks == [.lineInserted(line: second, index: 1)])
    let move = try doc.apply([.moveLines(ids: [second.id], after: nil)], origin: .agent, versions: [second.id: 0])
    #expect(doc.lines.map(\.id) == ["L2", first.id])
    #expect(doc.lines[0].words[0].id == "w3")
    #expect(move.hunks == [.lineMoved(lineID: "L2", from: 1, to: 0)])
    let deleted = doc.lines[0]
    let delete = try doc.apply([.deleteLines(ids: ["L2"])], origin: .agent, versions: ["L2": 1])
    #expect(delete.hunks == [.lineDeleted(line: deleted, index: 0)])
}
@Test func undoRemainsAvailableAcrossUnrelatedEditsOnly() throws {
    var doc = try seeded(); let id = doc.lines[0].id
    let txn = try doc.apply([.setKind(ids: [id], kind: .h1)], origin: .agent, versions: [id: 0])
    try doc.appendSegment(words: [Word(text: "other")])
    #expect(doc.canUndo(transactionID: txn.id))
    try doc.undo(transactionID: txn.id)
    #expect(doc.lines[0].kind == .p)
    #expect(doc.lines.count == 2)
    let later = try doc.apply([.setKind(ids: [id], kind: .li)], origin: .user, versions: [id: 2])
    try doc.apply([.setKind(ids: [id], kind: .h2)], origin: .user, versions: [id: 3])
    #expect(!doc.canUndo(transactionID: later.id))
    #expect(throws: DocumentError.undoUnavailable) { try doc.undo(transactionID: later.id) }
}

@Test func failedSecondOperationRollsBackEntireBatch() throws {
    var doc = try seeded(); let before = doc.snapshot; let id = doc.lines[0].id
    #expect(throws: DocumentError.unknownLine("missing")) {
        try doc.apply([.setKind(ids: [id], kind: .h1), .deleteLines(ids: ["missing"])], origin: .agent, versions: [id: 0])
    }
    #expect(doc.snapshot == before)
    #expect(doc.transactions.count == 1)
}
@Test func agentInsertedWordsHaveNoASRMetadata() throws {
    var doc = ComposerDocument()
    try doc.apply([.insertLines(after: nil, lines: [Line(words: [Word(text: "written", confidence: 0.8, alternatives: ["spoken"], pinned: true)])])], origin: .agent, versions: [:])
    #expect(doc.lines[0].words[0].confidence == nil)
    #expect(doc.lines[0].words[0].alternatives == nil)
    #expect(doc.lines[0].words[0].pinned == false)
}
@Test func structuralInversesRestoreWordRecordsAndOrder() throws {
    var doc = try seeded(); let first = doc.lines[0]
    try doc.appendSegment(words: [Word(text: "second")]); let second = doc.lines[1]
    let before = doc.lines
    let delete = try doc.apply([.deleteLines(ids: [first.id, second.id])], origin: .agent, versions: [first.id: 0, second.id: 0])
    try doc.undo(transactionID: delete.id)
    #expect(doc.lines.map(\.id) == before.map(\.id))
    #expect(doc.lines.flatMap(\.words) == before.flatMap(\.words))
    let move = try doc.apply([.moveLines(ids: [second.id], after: nil)], origin: .agent, versions: [second.id: doc.lines[1].version])
    try doc.undo(transactionID: move.id)
    #expect(doc.lines.map(\.id) == before.map(\.id))
}
@Test func publicationAndCodableRoundTrip() throws {
    let doc = try seeded()
    let transaction = try #require(doc.transactions.first)
    let publication = try #require(doc.publication(for: transaction))
    let data = try Foundation.JSONEncoder().encode(publication.event)
    #expect(try Foundation.JSONDecoder().decode(DocumentEvent.self, from: data) == .ops(transaction))
    #expect(doc.snapshotPublication.event == .snapshot(doc.snapshot))
}
