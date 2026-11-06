import Foundation
import Testing
import LegatoRoom
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct VoiceIsolationTests {
    private var audio: Data { Data(repeating: 32, count: 16000 * 2 * 8) }
    @Test func uncertainAndMatchingSpeechReachRoomWithoutWaiting() async throws {
        for score: Float in [0.1, 0.3, 0.5, 0.8] {
            let room = Room(), socket = FakeSocket()
            let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
            var iterator = tails.makeAsyncIterator()
            let client = SonioxClient(room: room, socket: socket, voiceIsolationEnabled: true, voiceMatcher: { _ in score })
            try await client.start(apiKey: "test")
            try await client.sendAudio(audio)
            await socket.feed(#"{"tokens":[{"text":" my words","is_final":false,"start_ms":100,"end_ms":900}]}"#)
            #expect(await iterator.next()?.payload["text"] == .string(" my words"))
            await socket.feed(#"{"tokens":[{"text":" my words.","is_final":true,"start_ms":100,"end_ms":1000},{"text":"<end>","is_final":true}]}"#)
            _ = await iterator.next()
            #expect(await room.documentSnapshot.text == "my words.")
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
    @Test func shortUntimedAndUnavailableContextPassImmediatelyAndNeverReplay() async {
        let filter = VoiceTokenFilter { _ in Issue.record("No matching unavailable audio"); return 0.1 }
        await filter.append(Data(repeating: 32, count: 3200))
        let words = [SonioxToken(text: "short", isFinal: true, startMs: 0, endMs: 80),
                     SonioxToken(text: "untimed", isFinal: true),
                     SonioxToken(text: "future", isFinal: true, startMs: 3000, endMs: 4000)]
        let immediate = await filter.filter(words, force: false)
        #expect(immediate.tokens == words && !immediate.withheld)
        await filter.append(audio)
        #expect(await filter.filter([], force: false).tokens.isEmpty)
        #expect(await filter.filter([], force: true).tokens.isEmpty)
    }
    @Test func sustainedStrongOtherEvidenceBlocksNewBinsAndKeepsPartialFinalDecision() async {
        let matcher = MutableMatcher(score: 0.1)
        let filter = VoiceTokenFilter { await matcher.match($0) }
        await filter.append(audio)
        let first = SonioxToken(text: "first", isFinal: true, startMs: 500, endMs: 900)
        let second = SonioxToken(text: "second", isFinal: true, startMs: 1000, endMs: 1400)
        #expect(await filter.filter([first, second], force: false).tokens == [first, second])
        let provisional = SonioxToken(text: " other", isFinal: false, startMs: 1500, endMs: 1900)
        #expect(await filter.filter([provisional], force: false).tokens.isEmpty)
        await matcher.setScore(0.9)
        let final = SonioxToken(text: " other.", isFinal: true, startMs: 1500, endMs: 2000)
        #expect(await filter.filter([final], force: true).tokens.isEmpty)
        #expect(await filter.filter([], force: true).tokens.isEmpty)
        let later = SonioxToken(text: "mine", isFinal: true, startMs: 2500, endMs: 2900)
        #expect(await filter.filter([later], force: false).tokens == [later])
    }
    @Test func admittedPartialStaysAdmittedWhenScoresDropAndPositiveMatchHasGrace() async {
        let matcher = MutableMatcher(score: 0.8)
        let filter = VoiceTokenFilter { await matcher.match($0) }
        await filter.append(audio)
        let partial = SonioxToken(text: " mine", isFinal: false, startMs: 500, endMs: 900)
        #expect(await filter.filter([partial], force: false).tokens == [partial])
        await matcher.setScore(0.01)
        for start in [1000.0, 1500, 2000] {
            let word = SonioxToken(text: "continued", isFinal: true, startMs: start, endMs: start + 400)
            #expect(await filter.filter([word], force: false).tokens == [word])
        }
        let background = SonioxToken(text: "background", isFinal: true, startMs: 2500, endMs: 2900)
        #expect(await filter.filter([background], force: false).tokens.isEmpty)
        let final = SonioxToken(text: " mine.", isFinal: true, startMs: 500, endMs: 1100)
        #expect(await filter.filter([final], force: true).tokens == [final])
    }
    @Test func pauseEndsPositiveGraceAndBackgroundDoesNotBorrowOldVoiceContext() async {
        let matcher = MutableMatcher(score: 0.8)
        let filter = VoiceTokenFilter { await matcher.match($0) }
        await filter.append(audio)
        let own = SonioxToken(text: "mine", isFinal: true, startMs: 500, endMs: 900)
        #expect(await filter.filter([own], force: false).tokens == [own])
        await matcher.setScore(0.01)
        for start in [2000.0, 2500] {
            let word = SonioxToken(text: "background", isFinal: true, startMs: start, endMs: start + 400)
            #expect(await filter.filter([word], force: false).tokens == [word])
        }
        let background = SonioxToken(text: "blocked", isFinal: true, startMs: 3000, endMs: 3400)
        #expect(await filter.filter([background], force: false).tokens.isEmpty)
        #expect(await filter.filter([], force: true).tokens.isEmpty)
    }

    @Test func earlyFinalsAndBoundariesNeverWaitBehindUnknownContext() async {
        let filter = VoiceTokenFilter { _ in 0.1 }
        let words = [SonioxToken(text: "first", isFinal: true, startMs: 3000, endMs: 3500),
                     SonioxToken(text: "second", isFinal: true, startMs: 100, endMs: 200),
                     SonioxToken(text: "<end>", isFinal: true)]
        #expect(await filter.filter(words, force: false).tokens == words)
        await filter.append(audio)
        #expect(await filter.filter([], force: true).tokens.isEmpty)
    }
    @Test func matcherFailureShowsUnavailableAndContinuesDictation() async throws {
        let room = Room(), socket = FakeSocket()
        let events = await room.subscribe(participant: .ui, channels: [.session], buffering: .unbounded)
        var iterator = events.makeAsyncIterator()
        let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
        var tail = tails.makeAsyncIterator()
        let client = SonioxClient(room: room, socket: socket, voiceIsolationEnabled: true, voiceMatcher: { _ in throw SonioxError.network })
        try await client.start(apiKey: "test")
        try await client.sendAudio(audio)
        await socket.feed(#"{"tokens":[{"text":"Keep my words.","is_final":true,"start_ms":100,"end_ms":500},{"text":"<end>","is_final":true}]}"#)
        _ = await tail.next()
        while let event = await iterator.next() {
            if event.payload["event"] == .string("asr.voiceIsolation") && event.payload["status"] == .string("unavailable") { break }
        }
        #expect(await client.lastFailure == nil)
        #expect(await client.isStreaming)
        #expect(await room.documentSnapshot.text == "Keep my words.")
        await socket.feed(#"{"tokens":[{"text":" Still listening.","is_final":true,"start_ms":1000,"end_ms":1500},{"text":"<end>","is_final":true}]}"#)
        _ = await tail.next()
        #expect(await room.documentSnapshot.text.contains("Still listening."))
        await client.close()
    }
}

private actor MutableMatcher {
    private var score: Float
    init(score: Float) { self.score = score }
    func setScore(_ value: Float) { score = value }
    func match(_ samples: [Float]) -> Float { score }
}
