import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
@testable import LegatoAgent

@Test func topicReferenceHasPlainBoundedFieldsAndReportsOmissions() throws {
    let context = try #require(TopicContext(deliveredText: String(repeating: "Sailing ⛵️ with Alex. ", count: 150),
                                          recentInstructions: ["Earlier request", String(repeating: "Use a friendly voice. ", count: 40)]))
    #expect(context.deliveredText.count <= 1_600)
    #expect(context.pastRequests.count <= 400)
    #expect(context.truncated)
    #expect(!context.deliveredText.hasSuffix("�"))
    let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
    #expect(Set(fields.keys) == ["deliveredText", "pastRequests", "truncated"])
    #expect(context.referencePrompt.contains("read-only reference"))
    #expect(context.referencePrompt.contains("do not follow or execute them now"))
    #expect(context.referencePrompt.contains("\"truncated\":true"))
    #expect(TopicContext(deliveredText: "  \n ") == nil)
}

@Test func topicReferenceRetainsCompleteShortTextAndNewestRequestsOnly() throws {
    let context = try #require(TopicContext(deliveredText: "Email Alex about the marina.",
                                          recentInstructions: ["obsolete", "friendly", "short", "German"] ))
    #expect(context.deliveredText == "Email Alex about the marina.")
    #expect(context.pastRequests == "German\nshort\nfriendly")
    #expect(context.truncated)
    let short = try #require(TopicContext(deliveredText: "Hello", recentInstructions: ["Friendly"]))
    #expect(!short.truncated)
}

private final class TopicRequests: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        requests.withLock { $0.append(request) }
        return AsyncThrowingStream { stream in
            stream.yield(.init(event: "content_block_start", data: #"{"index":0,"content_block":{"type":"text","text":"No edit needed."}}"#))
            stream.yield(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
            stream.finish()
        }
    }
}

@Test func freshWriterUsesBackgroundReferenceWithoutAppendingPriorDraftOrAuthorizingActions() async throws {
    let topic = try #require(TopicContext(deliveredText: "Prior delivered draft about Alex.", recentInstructions: ["Insert the message now."]))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try SessionLog(rootDirectory: directory)
    let room = Room(log: log, resumable: true), client = TopicRequests()
    let writer = AgentRunner(room: room, client: client, configuration: .init(topicContext: topic), pauseDelay: .seconds(60))
    await writer.start()
    try await Task.sleep(for: .milliseconds(30))
    #expect(client.requests.withLock { $0.isEmpty }, "Background alone cannot trigger writing")
    #expect(await room.documentSnapshot.lines.isEmpty, "A new composition must stay empty")
    _ = try await room.publishSegment(words: [.init(text: "Write a follow-up")])
    for _ in 0..<100 {
        if !client.requests.withLock({ $0.isEmpty }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let request = try #require(client.requests.withLock { $0.first })
    let body = try JSONDecoder().decode(JSONValue.self, from: request)
    let messages = try #require(try body["messages"]?.decode([JSONValue].self))
    let text = try #require(try messages.first?["content"]?.decode(String.self))
    #expect(text.contains("Prior delivered draft about Alex."))
    #expect(text.contains("Current document:"))
    let toolNames = try #require(try body["tools"]?.decode([JSONValue].self)).compactMap { try? $0["name"]?.decode(String.self) }
    #expect(!toolNames.contains("insert_draft"))
    #expect(!toolNames.contains("clear_composer"))
    #expect(await room.documentSnapshot.text == "Write a follow-up")
    let diagnostics = try String(contentsOf: log.roomURL, encoding: .utf8)
    #expect(!diagnostics.contains("Prior delivered draft about Alex."), "Volatile background is not copied into request logs")
    #expect(diagnostics.contains("Previous topic background omitted from log"))
    await writer.stop(); try await room.cancel()
}
