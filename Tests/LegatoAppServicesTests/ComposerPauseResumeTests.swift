import Foundation
import Testing
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAppServices

@MainActor @Test func recordAfterPauseWaitsForFinalPassAndRetainsDraftSessionAndMode() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try SessionLog(rootDirectory: root)
    let room = Room(resumable: true)
    let session = ComposerSession(room: room, log: log)
    _ = try await room.appendSegment(words: [.init(text: "Keep this draft")])
    await session.refreshDebugState()
    await session.setMode(.prompt)
    let id = session.sessionID
    try await room.micOff(transcriberDraining: true)
    let resume = Task { await session.resumeSession(debug: true) }
    try await Task.sleep(for: .milliseconds(60))
    #expect(await room.state == .trailing)
    #expect(session.renderedText == "Keep this draft")
    await room.finishTranscription()
    try await room.finishFinalPass()
    await resume.value
    #expect(session.isListening)
    #expect(await room.state == .listening)
    #expect(session.sessionID == id)
    #expect(session.mode == .prompt)
    #expect(session.renderedText == "Keep this draft")
    try await session.injectDebugText("More instructions", isFinal: true, startMs: 0)
    await session.cancel()
    #expect(session.renderedText.isEmpty)
}

@MainActor @Test func clearDuringQueuedRecordCannotRestartOrRestoreOldComposition() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try SessionLog(rootDirectory: root)
    let room = Room(resumable: true)
    let session = ComposerSession(room: room, log: log)
    _ = try await room.appendSegment(words: [.init(text: "Discard")])
    await session.refreshDebugState()
    try await room.micOff(transcriberDraining: true)
    let resume = Task { await session.resumeSession(debug: true) }
    try await Task.sleep(for: .milliseconds(60))
    await session.cancel()
    await resume.value
    await session.refreshDebugState()
    #expect(session.status == "idle")
    #expect(session.sessionID == nil)
    #expect(session.renderedText.isEmpty)
    #expect(!session.isListening)
}

@MainActor @Test func successfulInsertDetachesAndClearsComposition() async throws {
    let room = Room(resumable: true)
    let session = ComposerSession(room: room)
    _ = try await room.appendSegment(words: [.init(text: "Delivered")])
    await session.refreshDebugState()
    await session.insert()
    await session.refreshDebugState()
    #expect(session.status == "idle")
    #expect(session.renderedText.isEmpty)
    #expect(session.sessionID == nil)
    #expect(await room.state == .done)
}
