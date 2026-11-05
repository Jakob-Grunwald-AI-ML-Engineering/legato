import Foundation
import Testing
import LegatoRoom
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct VoiceIsolationTests {
    private var audio: Data { Data(repeating: 32, count: 16000 * 2 * 4) }
    @Test func provisionalAndFinalSpeechAreGatedBeforeRoom() async throws {
        for score: Float in [0.1, 0.5, 0.8] {
            let room = Room(), socket = FakeSocket()
            let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
            var iterator = tails.makeAsyncIterator()
            let client = SonioxClient(room: room, socket: socket, voiceIsolationEnabled: true, voiceMatcher: { _ in score })
            try await client.start(apiKey: "test")
            try await client.sendAudio(audio)
            await socket.feed(#"{"tokens":[{"text":" private words","is_final":false,"start_ms":100,"end_ms":900}]}"#)
            let tail = await iterator.next()
            #expect(tail?.payload["text"] == .string(score > 0.58 ? " private words" : ""))
            await socket.feed(#"{"tokens":[{"text":" private words.","is_final":true,"start_ms":100,"end_ms":900},{"text":"<end>","is_final":true}]}"#)
            _ = await iterator.next()
            #expect(await room.documentSnapshot.text == (score > 0.58 ? "private words." : ""))
            #expect(await socket.sent().contains(.binary(audio)))
            await client.close()
        }
    }
    @Test func offAndMeetingsBypassMatcherAndPreserveUntimedText() async throws {
        for meeting in [false, true] {
            let room = Room(), socket = FakeSocket()
            let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
            var iterator = tails.makeAsyncIterator()
            let client = SonioxClient(room: room, config: SonioxConfig(diarization: meeting), socket: socket,
                voiceIsolationEnabled: meeting, voiceMatcher: { _ in Issue.record("Matcher must be bypassed"); return 0 })
            try await client.start(apiKey: "test")
            await socket.feed(#"{"tokens":[{"text":"Everyone.","is_final":true},{"text":"<end>","is_final":true}]}"#)
            _ = await iterator.next()
            #expect(await room.documentSnapshot.text == "Everyone.")
            await client.close()
        }
    }
    @Test func shortUncertainSpeechIsNeverReleasedWithoutMatch() async throws {
        let filter = VoiceTokenFilter { _ in 0.9 }
        await filter.append(Data(repeating: 32, count: 3200))
        let word = SonioxToken(text: "secret", isFinal: true, startMs: 0, endMs: 80)
        let buffered = try await filter.filter([word], force: false)
        #expect(buffered.tokens.isEmpty)
        let flushed = try await filter.filter([], force: true)
        #expect(flushed.tokens.isEmpty && flushed.withheld)
    }
    @Test func missingTokenTimesAndExpiredAudioAreWithheld() async throws {
        let filter = VoiceTokenFilter { _ in Issue.record("No matching unavailable audio"); return 0.9 }
        await filter.append(Data(repeating: 32, count: 32 * 16000 * 2))
        let result = try await filter.filter([
            .init(text: "untimed", isFinal: true),
            .init(text: "expired", isFinal: true, startMs: 0, endMs: 100)
        ], force: true)
        #expect(result.tokens.isEmpty && result.withheld)
    }
    @Test func unresolvedEarlierFinalsKeepLaterWordsAndBoundariesInOrder() async throws {
        let filter = VoiceTokenFilter { _ in 0.9 }
        await filter.append(Data(repeating: 32, count: 2 * 16000 * 2))
        let buffered = try await filter.filter([
            .init(text: "earlier", isFinal: true, startMs: 3000, endMs: 3500),
            .init(text: "later", isFinal: true, startMs: 100, endMs: 200),
            .init(text: "<end>", isFinal: true)
        ], force: false)
        #expect(buffered.tokens.isEmpty)
        await filter.append(Data(repeating: 32, count: 3 * 16000 * 2))
        let released = try await filter.filter([], force: false)
        #expect(released.tokens.map(\.text) == ["earlier", "later", "<end>"])
    }

    @Test func matcherFailureFailsVisibleAndNeverPublishesWords() async throws {
        let room = Room(), socket = FakeSocket()
        let events = await room.subscribe(participant: .ui, channels: [.session], buffering: .unbounded)
        var iterator = events.makeAsyncIterator()
        let client = SonioxClient(room: room, socket: socket, voiceIsolationEnabled: true, voiceMatcher: { _ in throw SonioxError.network })
        try await client.start(apiKey: "test")
        try await client.sendAudio(audio)
        await socket.feed(#"{"tokens":[{"text":"private.","is_final":true,"start_ms":100,"end_ms":500}]}"#)
        while let event = await iterator.next() {
            if event.payload["event"] == .string("asr.error") { break }
        }
        #expect(await client.lastFailure != nil)
        #expect(await room.documentSnapshot.text == "")
    }
}
