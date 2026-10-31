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

@MainActor @Test func insertPreparationWaitsForDrainedAuthoringAndCapturesLatestDraft() async throws {
    let room = Room(resumable: true)
    let session = ComposerSession(room: room)
    _ = try await room.appendSegment(words: [.init(text: "Rough notes")])
    await session.refreshDebugState()
    try await room.micOff(transcriberDraining: true)
    let insertion = Task { try await session.prepareForInsertion() }
    try await Task.sleep(for: .milliseconds(50))
    let before = await room.documentSnapshot
    let line = try #require(before.lines.first)
    _ = try await room.applyDocument([.replaceInLine(lineID: line.id, old: "Rough notes", new: "A useful, authored prompt.")], origin: .agent, versions: [line.id: line.version])
    await room.finishTranscription()
    #expect(try await insertion.value == "A useful, authored prompt.")
    #expect(session.renderedText == "A useful, authored prompt.")
    #expect(await room.state == .paused)
    await session.cancel()
}

@MainActor @Test func insertPreparationTimeoutRetainsDraftAndCanRetry() async throws {
    let room = Room(resumable: true)
    let session = ComposerSession(room: room)
    _ = try await room.appendSegment(words: [.init(text: "Keep on timeout")])
    await session.refreshDebugState()
    try await room.micOff(transcriberDraining: true)
    await #expect(throws: NSError.self) { _ = try await session.prepareForInsertion(timeout: .milliseconds(40)) }
    #expect(session.renderedText == "Keep on timeout")
    await room.finishTranscription()
    #expect(try await session.prepareForInsertion() == "Keep on timeout")
    await session.cancel()
}

@MainActor @Test func offlineDebugSeedInsertsWithoutMicrophoneOrWriter() async throws {
    let session = ComposerSession()
    let result = try await session.debugControl("composer-debug-seed", args: ["Native insertion fixture"])
    #expect(result["inputSource"] as? String == "debug.seed")
    #expect(!session.isArmed)
    #expect(!session.isListening)
    #expect(try await session.prepareForInsertion() == "Native insertion fixture")
    await session.insert()
    #expect(session.renderedText.isEmpty)
}

@MainActor @Test func inputChannelSurvivesPauseResumeAndResetsAfterInsertAndCancel() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let room = Room(resumable: true), log = try SessionLog(rootDirectory: root)
    let session = ComposerSession(room: room, log: log)
    _ = try await room.appendSegment(words: [.init(text: "Retain this draft")])
    await session.refreshDebugState()
    await session.setInputMode(.instructions)
    try await room.micOff(); try await room.finishFinalPass()
    await session.resumeSession(debug: true)
    #expect(session.inputMode == .instructions)
    #expect(session.renderedText == "Retain this draft")
    await session.insert()
    #expect(session.inputMode == .dictation)
    await session.setInputMode(.instructions)
    await session.cancel()
    #expect(session.inputMode == .dictation)
    #expect(session.instructionPreview.isEmpty)
}

@MainActor @Test func insertKeepsUnsentInstructionPausedWithoutApplyingOrRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try SessionLog(rootDirectory: root), room = Room(segmentRouting: .intercepted, resumable: true)
    let binder = HintBinder(room: room, requiresExplicitSubmission: true)
    let session = ComposerSession(room: room, log: log, binder: binder)
    let stream = await room.subscribe(participant: .ui, channels: [.instructionDraft, .writingInstruction])
    let receiver = Task { for await event in stream { await session.receive(event) } }
    defer { receiver.cancel() }
    await binder.start()
    _ = try await room.appendSegment(words: [.init(text: "Delivered draft")])
    await binder.setInputMode(.instructions, timestamp: 100)
    _ = try await room.publishSegment(words: [.init(text: "Keep this pending comment")], tOrigin: 101)
    for _ in 0..<100 { if !session.instructionDraft.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(!session.instructionDraft.isEmpty)
    try await room.micOff(); try await room.finishFinalPass()
    await session.refreshDebugState()
    let id = session.sessionID, comment = session.instructionDraft
    #expect(try await session.prepareForInsertion() == "Delivered draft")
    await session.insert()
    #expect(session.renderedText.isEmpty && session.status == "paused")
    #expect(session.sessionID == id && session.instructionDraft == comment)
    #expect(!session.isListening && !session.isArmed && !session.instructionApplying)
    #expect(await room.state == .paused)
    #expect(await binder.hasUnsentInstruction)
    await session.discardInstruction()
    #expect(session.instructionPreview.isEmpty)
    #expect(!(await binder.hasUnsentInstruction))
    await session.cancel()
}
