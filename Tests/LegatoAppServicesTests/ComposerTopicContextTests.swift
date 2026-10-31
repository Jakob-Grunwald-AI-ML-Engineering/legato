import Foundation
import Testing
import LegatoAgent
import LegatoRoom
@testable import LegatoAppServices

@MainActor @Test func deliveredTopicSurvivesDraftClearButNewTopicDiscardsBoth() async throws {
    let session = ComposerSession()
    try await session.seedDebugDraft("Meet Alex at the marina on Friday.")
    let events = Room()
    await session.receive(try await events.publish(channel: .writingInstruction, participant: .hintBinder,
        payload: .object(["event": .string("global.instruction"), "captureID": .string("private-id"), "text": .string("Keep it friendly.")])))
    await session.insert()
    let retained = try #require(session.topicContext)
    #expect(retained.deliveredText == "Meet Alex at the marina on Friday.")
    #expect(retained.pastRequests == "Keep it friendly.")
    #expect(!retained.referencePrompt.contains("private-id"))
    #expect(session.renderedText.isEmpty)
    try await session.seedDebugDraft("Unsent replacement")
    await session.cancel()
    #expect(session.topicContext == retained, "X discards only the new, unsent draft")
    try await session.seedDebugDraft("Another unsent draft")
    await session.setInputMode(.instructions)
    await session.startNewTopic()
    #expect(session.topicContext == nil)
    #expect(session.renderedText.isEmpty)
    #expect(session.inputMode == .dictation)
    #expect(ComposerSession().topicContext == nil, "Topic data is volatile, not restored from disk")
}

@MainActor @Test func preparingWithoutDeliveryDoesNotReplaceTopicAndNextDeliveryReplacesIt() async throws {
    let session = ComposerSession()
    try await session.seedDebugDraft("First delivered topic")
    await session.insert()
    let retained = session.topicContext
    try await session.seedDebugDraft("Prepared but delivery failed")
    #expect(try await session.prepareForInsertion() == "Prepared but delivery failed")
    #expect(session.topicContext == retained, "Preparing is not a delivery acknowledgement")
    await session.cancel()
    #expect(session.topicContext == retained)
    try await session.seedDebugDraft("New successfully delivered topic")
    await session.insert()
    #expect(session.topicContext?.deliveredText == "New successfully delivered topic")
    #expect(session.topicContext?.pastRequests.isEmpty == true)
    #expect(session.topicContext?.referencePrompt.contains("First delivered topic") == false)
    await session.startNewTopic()
}
