import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAgent

private final class TargetedMessages: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let line: String
    let version: Int
    init(line: String, version: Int) { self.line = line; self.version = version }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let first = requests.withLock { values in values.append(request); return values.count == 1 }
        return AsyncThrowingStream { continuation in
            let block: JSONValue = first
                ? .object(["type": .string("tool_use"), "id": .string("correction"), "name": .string("replace_in_line"),
                           "input": .object(["line": .string(line), "version": .number(Double(version)),
                                             "old": .string("Alex"), "new": .string("Morgan")])])
                : .object(["type": .string("text"), "text": .string("Done")])
            let payload: JSONValue = .object(["index": .number(0), "content_block": block])
            continuation.yield(.init(event: "content_block_start", data: String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)))
            continuation.yield(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
            continuation.finish()
        }
    }
}

@Test func targetedChunkReachesWritingAgentToolPathWithoutRawTranscriptOrTapTurn() async throws {
    let room = Room(segmentRouting: .intercepted)
    try await room.appendSegment(words: [Word(text: "Hi"), Word(id: "selected", text: "Alex")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let client = TargetedMessages(line: line.id, version: line.version)
    let runner = AgentRunner(room: room, client: client)
    let binder = HintBinder(room: room)
    await binder.start()
    await runner.start()
    try await binder.tap(lineID: line.id, wordID: "selected", timestamp: 100)
    try await room.publish(channel: .asrSegment, participant: .segmenter,
                           payload: .object(["words": try .encoding([Word(text: "Use"), Word(text: "Morgan"), Word(text: "instead.")])]), tOrigin: 101)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await binder.requestSend(timestamp: 102))
    try await room.publish(channel: .asrBoundary, participant: .segmenter,
                           payload: .object(["reason": .string("finalize")]), tOrigin: 102)
    for _ in 0..<100 {
        if client.requests.withLock({ $0.count >= 2 }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let requests = client.requests.withLock { $0 }
    #expect(requests.count == 2, "A tap must not create its own writing-agent turn")
    let first = try JSONDecoder().decode(JSONValue.self, from: #require(requests.first))
    let messages = try #require(first["messages"]).decode([JSONValue].self)
    let context = try #require(messages.first?["content"]).decode(String.self)
    #expect(context.contains("targeted.speech"))
    #expect(context.contains("selected") && context.contains("Use Morgan instead."))
    #expect(!context.contains("asr.segment"), "Raw targeted ASR must not also enter general writing history")
    #expect(await room.documentSnapshot.text == "Hi Morgan")
    #expect(await room.documentSnapshot.lines.count == 1)
    #expect(await room.documentSnapshot.lines.first?.words.last?.pinned == false)
    await runner.stop()
    await binder.stop()
}
