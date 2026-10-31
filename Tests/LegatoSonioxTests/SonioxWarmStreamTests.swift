import Foundation
import Testing
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct SonioxWarmStreamTests {
    @Test func idleDropBeforeAudioIsQuietAndReportsDrop() async throws {
        let room = Room()
        let session = await room.subscribe(participant: .ui, channels: [.session], buffering: .unbounded)
        let socket = FakeSocket()
        let dropped = DropCounter()
        let client = SonioxClient(room: room, socket: socket, quietFailure: .untilAudio, onDrop: { await dropped.hit() })
        try await client.start(apiKey: "test")
        await socket.drop()
        while await dropped.count == 0 { await Task.yield() }
        var events: [String] = []
        for await event in session {
            if case .string(let name) = event.payload["event"] { events.append(name) }
            if events.contains("asr.dropped") { break }
        }
        #expect(!events.contains("asr.error"), "A warm stream that never carried audio must not fail the composition")
        #expect(!(await client.isStreaming))
    }

    @Test func dropAfterAudioStillFailsVisibly() async throws {
        let room = Room()
        let session = await room.subscribe(participant: .ui, channels: [.session], buffering: .unbounded)
        let socket = FakeSocket()
        let dropped = DropCounter()
        let client = SonioxClient(room: room, socket: socket, quietFailure: .untilAudio, onDrop: { await dropped.hit() })
        try await client.start(apiKey: "test")
        try await client.sendAudio(Data([1, 2]))
        await socket.drop()
        for await event in session where event.payload["event"] == .string("asr.error") { break }
        #expect(await dropped.count == 0)
    }

    @Test func closeDropsUnsegmentedWordsWithoutErrorOrFinalize() async throws {
        let room = Room()
        let socket = FakeSocket()
        let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
        var tail = tails.makeAsyncIterator()
        let client = SonioxClient(room: room, socket: socket)
        try await client.start(apiKey: "test")
        await socket.feed(#"{"tokens":[{"text":"Half","is_final":true},{"text":" spo","is_final":false}]}"#)
        _ = await tail.next()
        await client.close()
        #expect(await tail.next()?.payload["text"] == .string(""))
        #expect(await room.documentSnapshot.lines.isEmpty, "Half-spoken words are dropped, never committed")
        let sent = await socket.sent()
        #expect(!sent.contains(.text(#"{"type":"finalize"}"#)))
        #expect(!(await client.isStreaming))
    }
}

private actor DropCounter {
    var count = 0
    func hit() { count += 1 }
}

extension FakeSocket {
    /// The transport goes away, whether or not the receive loop is waiting yet.
    func drop() { dropped = true; waiter?.resume(throwing: SonioxError.network); waiter = nil }
}
