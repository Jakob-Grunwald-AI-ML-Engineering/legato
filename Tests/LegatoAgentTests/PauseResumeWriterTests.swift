import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAgent

private final class ContinuingWriter: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        requests.withLock { $0.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(event: "content_block_start", data: #"{"index":0,"content_block":{"type":"text","text":"Remember the earlier instructions."}}"#))
            continuation.yield(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
            continuation.finish()
        }
    }
}

@Test func pausedCompositionRetainsWriterConversationForFollowUpInstructions() async throws {
    let room = Room(resumable: true), client = ContinuingWriter()
    let runner = AgentRunner(room: room, client: client, pauseDelay: .seconds(60))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "Original instructions")])
    for _ in 0..<100 {
        if !client.requests.withLock({ $0.isEmpty }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try await room.micOff()
    for _ in 0..<100 {
        if await room.state == .paused { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await room.state == .paused)
    let count = client.requests.withLock { $0.count }
    try await room.resume()
    _ = try await room.publishSegment(words: [.init(text: "Make it friendlier")])
    for _ in 0..<100 {
        if client.requests.withLock({ $0.count > count }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let latest = try #require(client.requests.withLock { $0.last })
    let body = String(decoding: latest, as: UTF8.self)
    #expect(body.contains("Remember the earlier instructions."))
    #expect(body.contains("Original instructions"))
    #expect(body.contains("Make it friendlier"))
    #expect(await room.documentSnapshot.lines.count == 2)
    await runner.stop()
    try await room.cancel()
}
