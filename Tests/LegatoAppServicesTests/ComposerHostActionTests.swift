import Testing
import LegatoAgent
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAppServices

@MainActor @Test func staleClearActionCannotEraseNewCompositionAndMissingTargetKeepsDraft() async throws {
    let room = Room()
    _ = try await room.appendSegment(words: [.init(text: "Keep this draft")])
    let session = ComposerSession(room: room)
    await session.refreshDebugState()
    let context = try #require(session.captureHostActionContext())
    let insert = ComposerHostAction(id: "insert-1", instructionID: "instruction-1", kind: .insertDraft, context: context)
    let failed = await session.performHostAction(insert)
    #expect(!failed.succeeded)
    #expect(session.successfulInsertionID == nil)
    #expect(session.renderedText == "Keep this draft")
    #expect(session.hostActionNotice?.contains("Draft kept") == true)
    var delivered = 0
    session.hostInsertionTarget = { "new-target" }
    session.hostInsertDraft = { _ in delivered += 1; return .init(succeeded: true, message: "Wrong") }
    #expect(!(await session.performHostAction(insert)).succeeded, "A duplicate instruction cannot retry against a newly bound target")
    #expect(delivered == 0)
    await session.cancel()
    let staleClear = ComposerHostAction(id: "clear-1", instructionID: "instruction-2", kind: .clearComposer, context: context)
    #expect(!(await session.performHostAction(staleClear)).succeeded)
}

@MainActor @Test func changedTargetRejectsVoiceInsertWithoutCallingPlatformWriter() async throws {
    let room = Room()
    _ = try await room.appendSegment(words: [.init(text: "A complete message")])
    let session = ComposerSession(room: room)
    await session.refreshDebugState()
    session.hostInsertionTarget = { "field-one" }
    let context = try #require(session.captureHostActionContext())
    session.hostInsertionTarget = { "field-two" }
    var writes = 0
    session.hostInsertDraft = { _ in writes += 1; return .init(succeeded: true, message: "Unexpected") }
    let action = ComposerHostAction(id: "tool", instructionID: "instruction", kind: .insertDraft, context: context)
    #expect(!(await session.performHostAction(action)).succeeded)
    #expect(writes == 0)
    #expect(session.renderedText == "A complete message")
}
