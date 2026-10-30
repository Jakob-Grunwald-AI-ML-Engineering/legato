import Foundation
import Testing
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoSoniox

@Suite struct SonioxTests {
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
    @Test func protocolFinalizationKeepaliveAndErrors() async throws {
        let socket = FakeSocket()
        let client = SonioxClient(room: Room(), config: SonioxConfig(), socket: socket, keepaliveInterval: .milliseconds(5))
        try await client.start(apiKey: "test")
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
    let input = AsyncStream<SonioxFrame>.makeStream()
    var iterator: AsyncStream<SonioxFrame>.Iterator
    init() { iterator = input.stream.makeAsyncIterator() }
    func connect(request: URLRequest) async throws {}
    func send(_ frame: SonioxFrame) async throws { messages.append(frame) }
    func receive() async throws -> SonioxFrame {
        // Only one receive loop consumes this stream.
        var next = iterator
        let result = await next.next()
        iterator = next
        return result ?? .text("{}")
    }
    func close() async { input.continuation.finish() }
    func feed(_ text: String) { input.continuation.yield(.text(text)) }
    func sent() -> [SonioxFrame] { messages }
}
