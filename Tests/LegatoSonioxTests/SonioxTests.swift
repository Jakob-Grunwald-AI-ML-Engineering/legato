import Foundation
import Testing
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoSoniox

@Suite(.timeLimit(.minutes(1))) struct SonioxTests {
    @Test func muteGatesAudioButKeepsSocketAndDrainsProviderBacklog() async throws {
        let room = Room()
        let socket = FakeSocket()
        let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
        var events = tails.makeAsyncIterator()
        let client = SonioxClient(room: room, socket: socket, keepaliveInterval: .milliseconds(5))
        try await client.start(apiKey: "test")
        let before = Data([1, 2]), muted = Data([3, 4]), after = Data([5, 6])
        try await client.sendAudio(before)
        try await client.setMuted(true)
        try await client.setMuted(true)
        try await client.sendAudio(muted)
        await socket.feed(#"{"tokens":[{"text":"Backlog","is_final":true},{"text":"<fin>","is_final":true}]}"#)
        _ = await events.next()
        #expect(await room.documentSnapshot.lines.first?.text == "Backlog")
        #expect(await room.state == .listening)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await socket.sent().contains(.text(#"{"type":"keepalive"}"#)))
        try await client.setMuted(false)
        try await client.sendAudio(after)
        let sent = await socket.sent()
        #expect(sent.filter { $0 == .text(#"{"type":"finalize"}"#) }.count == 1)
        #expect(sent.filter { if case .binary = $0 { true } else { false } } == [.binary(before), .binary(after)])
        #expect(!sent.contains(.text("")), "Muting cannot send end-of-stream or close the provider")
        await client.cancel()
    }
    @Test func targetedDraftFlushesLatestPartialOnceAfterPauses() async throws {
        let room = Room(segmentRouting: .intercepted)
        try await room.appendSegment(words: [Word(id: "target", text: "Alex")])
        let line = try #require(await room.documentSnapshot.lines.first)
        let binder = HintBinder(room: room)
        await binder.start()
        let tails = await room.subscribe(participant: .ui, channels: [.asrTail], buffering: .unbounded)
        var tail = tails.makeAsyncIterator()
        let hints = await room.subscribe(participant: .logger, channels: [.hint])
        var hint = hints.makeAsyncIterator()
        try await binder.tap(lineID: line.id, wordID: "target", timestamp: 100.05)
        _ = await tail.next() // Clear any general partial text at selection.
        let client = SonioxClient(room: room, audioOrigin: 100)
        try await client.startDebug()
        try await client.injectDebugFrame(#"{"tokens":[{"text":" Replace this name","is_final":false}]}"#)
        #expect(await tail.next()?.payload["text"] == .string(""))
        try await client.injectDebugFrame(#"{"tokens":[{"text":"Use Morgan.","is_final":true,"start_ms":100,"end_ms":400}]}"#)
        #expect(await tail.next()?.payload["text"] == .string(""))
        #expect(await room.documentSnapshot.text == "Alex")
        try await client.injectDebugFrame(#"{"tokens":[{"text":"Use the surname too.","is_final":true,"start_ms":450,"end_ms":800}]}"#)
        #expect(await tail.next()?.payload["text"] == .string(""))
        #expect(await room.documentSnapshot.text == "Alex")
        // Both punctuation segments already emptied the segmenter's words array.
        try await client.injectDebugFrame(#"{"tokens":[{"text":"<end>","is_final":true}]}"#)
        _ = await tail.next()
        try await client.injectDebugFrame(#"{"tokens":[{"text":" Make it brief","is_final":false,"start_ms":900,"end_ms":1100}]}"#)
        _ = await tail.next()
        #expect(await binder.requestSend(timestamp: 101.2))
        try await client.finalizeChunk()
        let event = try #require(await hint.next())
        #expect(event.payload["text"] == .string("Use Morgan. Use the surname too. Make it brief"))
        _ = await tail.next()
        try await client.injectDebugFrame(#"{"tokens":[{"text":"ordinary.","is_final":true,"start_ms":2000,"end_ms":2100}]}"#)
        _ = await tail.next()
        #expect(await room.documentSnapshot.text == "Alex\nordinary.")
        await client.cancel()
        await binder.stop()
    }

    @Test func silenceAfterPunctuationStillEmitsAnOrderedBoundary() {
        var segmenter = Segmenter()
        _ = segmenter.ingest([.init(text: "First.", isFinal: true, startMs: 0, endMs: 100)])
        let next = segmenter.ingest([.init(text: "Next.", isFinal: true, startMs: 1000, endMs: 1100)])
        #expect(next.events.count == 2)
        if case .boundary(let reason, let time) = next.events.first {
            #expect(reason == "gap" && time == 0.1)
        } else { Issue.record("Gap must precede the next chunk, even after punctuation") }
    }

    @Test func wordsAndSegmentsNeverCommitThePartialTail() {
        var pipeline = Segmenter()
        let first = pipeline.ingest([
            SonioxToken(text: "Gu", confidence: 0.95, isFinal: true, startMs: 0, endMs: 100, language: "de"),
            SonioxToken(text: "ten", confidence: 0.7, isFinal: true, startMs: 100, endMs: 200, language: "de"),
            SonioxToken(text: " Morgen", confidence: 0.9, isFinal: false)])
        #expect(first.segments.isEmpty)
        #expect(first.tail == "Guten Morgen")
        let final = pipeline.ingest([
            SonioxToken(text: " Morgen", confidence: 0.9, isFinal: true, startMs: 200, endMs: 400, language: "de"),
            SonioxToken(text: ".", confidence: 0.99, isFinal: true, startMs: 400, endMs: 400)])
        #expect(final.segments.count == 1)
        #expect(final.segments[0].words.map(\.word.text) == ["Guten", "Morgen."])
        #expect(final.segments[0].words[0].word.confidence == 0.7)
        #expect(final.segments[0].words[0].word.language == "de")
        #expect(final.segments[0].words[0].t0 == 0)
        #expect(final.tail.isEmpty)
    }
    @Test func endGapAndLimitsCloseSegments() {
        var p = Segmenter(maxWords: 2, maxDuration: 8, gap: 0.7)
        let output = p.ingest([
            .init(text: "one", isFinal: true, startMs: 0, endMs: 100),
            .init(text: " two", isFinal: true, startMs: 200, endMs: 300),
            .init(text: " three", isFinal: true, startMs: 1100, endMs: 1200),
            .init(text: "<end>", isFinal: true)])
        #expect(output.segments.flatMap(\.words).map(\.word.text) == ["one", "two", "three"])
        #expect(output.segments.count == 2)
        var duration = Segmenter(maxDuration: 8)
        #expect(duration.ingest([.init(text: "long", isFinal: true, startMs: 0, endMs: 8100), .init(text: "<end>", isFinal: true)]).segments[0].reason == "duration")
    }
    @Test func configCapsContextAndUsesHeader() throws {
        let config = SonioxConfig(mode: "Note", personalPrompt: String(repeating: "x", count: 40000), terms: (0..<150).map { "Term\($0)" })
        let json = try JSONDecoder().decode(JSONValue.self, from: config.message())
        #expect(json["model"] == .string("stt-rt-v5"))
        #expect(json["audio_format"] == .string("pcm_s16le"))
        #expect(config.terms.count == 100)
        #expect(config.estimatedContextTokens < 8000)
        #expect(config.request(apiKey: "secret").value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(!String(decoding: try config.message(), as: UTF8.self).contains("secret"))
    }
    @Test func providerFailuresReachTheRoomWithoutCredentials() async throws {
        for code in [401, 402, 408, 413, 429] {
            let room = Room()
            let events = await room.subscribe(participant: .logger, channels: [.session])
            var iterator = events.makeAsyncIterator()
            let socket = FakeSocket()
            let client = SonioxClient(room: room, socket: socket)
            try await client.start(apiKey: "never-log-this")
            _ = await iterator.next() // asr.started
            await socket.feed("{\"error_code\":\(code)}")
            let event = try #require(await iterator.next())
            #expect(event.payload["event"] == .string("asr.error"))
            #expect(event.payload["message"] == .string(SonioxError.provider(code).localizedDescription))
            #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("never-log-this"))
        }
    }
    @Test func protocolFinalizationKeepaliveAndErrors() async throws {
        let socket = FakeSocket()
        let room = Room()
        let tails = await room.subscribe(participant: .ui, channels: [.asrTail])
        var tailEvents = tails.makeAsyncIterator()
        let client = SonioxClient(room: room, config: SonioxConfig(), socket: socket, keepaliveInterval: .milliseconds(5))
        try await client.start(apiKey: "test")
        await socket.feed("{\"tokens\":[{\"text\":\"speculative\",\"is_final\":false}]}")
        let tail = await tailEvents.next()
        #expect(tail?.payload["text"] == .string("speculative"))
        #expect(await room.documentSnapshot.lines.isEmpty)
        try await Task.sleep(for: .milliseconds(25))
        let finishing = Task { try await client.finish() }
        while !(await socket.sent()).contains(.text("{\"type\":\"finalize\"}")) { await Task.yield() }
        await socket.feed("{\"tokens\":[{\"text\":\"<fin>\",\"is_final\":true}]}")
        while !(await socket.sent()).contains(.text("")) { await Task.yield() }
        await socket.feed("{\"finished\":true}")
        try await finishing.value
        #expect(await socket.sent().contains(.text("{\"type\":\"keepalive\"}")))
        for code in [401, 402, 408, 413, 429] {
            #expect(!SonioxError.provider(code).localizedDescription.isEmpty)
        }
    }
}

actor FakeSocket: SonioxSocket {
    var messages: [SonioxFrame] = []
    var inbox: [SonioxFrame] = []
    var waiter: CheckedContinuation<SonioxFrame, any Error>?
    var dropped = false
    func connect(request: URLRequest) async throws {}
    func send(_ frame: SonioxFrame) async throws { messages.append(frame) }
    func receive() async throws -> SonioxFrame {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if dropped { throw SonioxError.network }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { waiter?.resume(throwing: SonioxError.cancelled); waiter = nil }
    func feed(_ text: String) {
        if let waiter { self.waiter = nil; waiter.resume(returning: .text(text)) }
        else { inbox.append(.text(text)) }
    }
    func sent() -> [SonioxFrame] { messages }
}
