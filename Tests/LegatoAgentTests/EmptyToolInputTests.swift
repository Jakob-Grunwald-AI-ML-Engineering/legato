import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
@testable import LegatoAgent

private final class EmptyViewMessages: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let fragment: String
    init(fragment: String) { self.fragment = fragment }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let first = requests.withLock { $0.append(request); return $0.count == 1 }
        return AsyncThrowingStream { continuation in
            // Captured Mac UAT view shape, room seq455–459: initial {}, empty JSON delta.
            let start = #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"view1","name":"view","input":{}}}"#
            let fragmentJSON = String(decoding: try! JSONEncoder().encode(fragment), as: UTF8.self)
            let delta = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(fragmentJSON)}}"
            let frames = first ? [("content_block_start", start), ("content_block_delta", delta), ("content_block_stop", #"{"type":"content_block_stop","index":0}"#)] : [("content_block_start", #"{"index":0,"content_block":{"type":"text","text":"Done"}}"#)]
            var parser = SSEParser()
            for (type, data) in frames {
                for byte in "event: \(type)\ndata: \(data)\n\n".utf8 {
                    if let event = parser.consume(byte: byte) { continuation.yield(event) }
                }
            }
            continuation.finish()
        }
    }
}

@Test(arguments: ["", " \n\t", "{"])
func runnerAcceptsEmptyViewDeltaButRejectsTruncatedJSON(fragment: String) async throws {
    let room = Room()
    let client = EmptyViewMessages(fragment: fragment)
    let runner = AgentRunner(room: room, client: client)
    await runner.start()
    _ = try await room.publish(channel: .userIntent, participant: .ui, payload: .string("Inspect document"))
    for _ in 0..<100 {
        if client.requests.withLock({ $0.count >= 2 }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await runner.stop()
    let requests = client.requests.withLock { $0 }
    if fragment == "{" { #expect(requests.count == 1); return }
    #expect(requests.count == 2)
    let request = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last))
    let messages = try #require(request["messages"]).decode([JSONValue].self)
    let results = try #require(messages.last?["content"]).decode([JSONValue].self)
    #expect(results.first?["type"] == .string("tool_result"))
    #expect(results.first?["tool_use_id"] == .string("view1"))
    #expect(results.first?["is_error"] == .bool(false))
}
