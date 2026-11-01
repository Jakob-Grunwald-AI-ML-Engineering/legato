import Testing
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAgent

struct AcceptedSegmentTests {
    @Test func rawSegmentWaitsForBinderAndOnlyASRDocumentWritesTriggerContent() async throws {
        let room = Room(segmentRouting: .intercepted)
        let stream = await room.subscribe(participant: .logger, channels: [.docOps])
        let raw = try await room.publishSegment(words: [Word(text: "Normal content")])
        #expect(!AgentAdmission.isAcceptedContent(raw))
        _ = try await room.appendSegment(words: [Word(text: "Normal content")], causedBy: raw.id)
        var iterator = stream.makeAsyncIterator()
        let accepted = try #require(await iterator.next())
        #expect(AgentAdmission.isAcceptedContent(accepted))
        let snapshot = await room.documentSnapshot
        let line = try #require(snapshot.lines.first)
        _ = try await room.applyDocument([.replaceInLine(lineID: line.id, old: "Normal", new: "Edited")], origin: .agent, versions: [line.id: line.version])
        let ownEdit = try #require(await iterator.next())
        #expect(!AgentAdmission.isAcceptedContent(ownEdit))
        var policy = LiveAgentPolicy()
        policy.enqueue(raw); #expect(policy.begin() == nil)
        policy.enqueue(accepted); #expect(policy.begin()?.count == 1)
    }
}
