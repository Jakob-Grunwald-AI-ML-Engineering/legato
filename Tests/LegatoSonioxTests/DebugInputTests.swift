import Foundation
import Testing
import LegatoRoom
import LegatoComposerDoc
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct DebugInputTests {
    @Test func cancellingDebugInputRejectsFramesAndProductionStillRequiresKey() async throws {
        let client = SonioxClient(room: Room())
        try await client.startDebug()
        try await client.injectDebugFrame(#"{"tokens":[{"text":"pending","is_final":false}]}"#)
        await client.cancel()
        await #expect(throws: SonioxError.notConnected) { try await client.injectDebugFrame(#"{"tokens":[]}"#) }
        let production = SonioxClient(room: Room())
        await #expect(throws: SonioxError.missingKey) { try await production.start(apiKey: "") }
    }
    @Test func debugIngressUsesProviderDecodeAndKeepsPartialOutOfSegments() async throws {
        let room = Room(segmentRouting: .intercepted)
        let stream = await room.subscribe(participant: .logger, channels: [.asrSegment, .asrTail], buffering: .unbounded)
        var events = stream.makeAsyncIterator()
        let client = SonioxClient(room: room, audioOrigin: 100)
        try await client.startDebug()
        try await client.injectDebugFrame(#"{"tokens":[{"text":"Hallo","is_final":false,"confidence":0.4,"language":"de","start_ms":200,"end_ms":400}]}"#)
        #expect(await events.next()?.payload["text"] == .string("Hallo"))
        #expect(await room.documentSnapshot.lines.isEmpty)
        try await client.injectDebugFrame(#"{"tokens":[{"text":"Hallo","is_final":true,"confidence":0.4,"language":"de","start_ms":200,"end_ms":400},{"text":"<end>","is_final":true}]}"#)
        let segment = try #require(await events.next())
        #expect(segment.channel == .asrSegment)
        #expect(segment.tOrigin == 100.2)
        let words = try #require(segment.payload["words"]).decode([Word].self)
        #expect(words[0].confidence == 0.4)
        #expect(words[0].language == "de")
        _ = await events.next()
        try await client.finish()
        await client.cancel()
        await #expect(throws: SonioxError.self) { try await client.injectDebugFrame(#"{"tokens":[]}"#) }
    }
}
