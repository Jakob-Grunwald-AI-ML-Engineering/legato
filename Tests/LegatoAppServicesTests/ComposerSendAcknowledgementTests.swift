import Testing
@testable import LegatoAppServices

@MainActor @Test func acknowledgedDeliveryEmitsSuccessButClearAndNewTopicDoNot() async throws {
    let session = ComposerSession()
    try await session.seedDebugDraft("A complete delivered message")
    #expect(session.successfulInsertionID == nil)
    await session.insert() // The surface has acknowledged its external delivery.
    let acknowledgement = try #require(session.successfulInsertionID)
    #expect(session.snapshot.lines.isEmpty)
    try await session.seedDebugDraft("A different draft")
    await session.cancel()
    #expect(session.successfulInsertionID == acknowledgement)
    try await session.seedDebugDraft("Another topic")
    await session.startNewTopic()
    #expect(session.successfulInsertionID == acknowledgement)
    await session.insert() // An empty Insert cannot create a new flight.
    #expect(session.successfulInsertionID == acknowledgement)
}
