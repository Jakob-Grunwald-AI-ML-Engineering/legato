import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoClaude

/// Answers every request from a queue of canned responses and records what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body: String }
    struct Seen { var request: URLRequest; var body: Data }
    private struct State { var replies: [Reply] = []; var seen: [Seen] = [] }
    private static let state = Mutex(State())

    static func reset(_ replies: [Reply]) { state.withLock { $0 = State(replies: replies) } }
    static var seen: [Seen] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let reply = Self.state.withLock { state -> Reply in
            state.seen.append(Seen(request: request, body: body))
            return state.replies.isEmpty ? Reply(status: 500, body: "{}") : state.replies.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

private let ok = #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Hello"},{"type":"text","text":" there"}],"stop_reason":"end_turn"}"#

@Suite(.serialized) struct ClaudeBackendTests {
    private func rig(key: String? = "sk-test") -> (ClaudeBackend, SleepRecorder) {
        let sleeps = SleepRecorder()
        let backend = ClaudeBackend(
            keyStore: InMemoryAPIKeyStore(apiKey: key), session: session(), sleep: { sleeps.record($0) })
        return (backend, sleeps)
    }

    @Test func requestHasTheDocumentedHeadersAndBody() async throws {
        StubProtocol.reset([.init(status: 200, body: ok)])
        let (backend, _) = rig()
        let text = try await backend.respond(
            instructions: "Be brief.", examples: [LLMExample(user: "ex-in", assistant: "ex-out")], prompt: "the transcript")
        #expect(text == "Hello there")

        let seen = try #require(StubProtocol.seen.first)
        #expect(seen.request.httpMethod == "POST")
        #expect(seen.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(seen.request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(seen.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(seen.request.value(forHTTPHeaderField: "content-type") == "application/json")

        let json = try #require(JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect(json["max_tokens"] as? Int == 4096)
        #expect(json["system"] as? String == "Be brief.")
        #expect(json["thinking"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(messages.map { $0["content"] as? String } == ["ex-in", "ex-out", "the transcript"])
    }

    @Test func plainRespondSendsOnlyThePrompt() async throws {
        StubProtocol.reset([.init(status: 200, body: ok)])
        let (backend, _) = rig()
        _ = try await backend.respond(instructions: "I", prompt: "P")
        let json = try #require(JSONSerialization.jsonObject(with: StubProtocol.seen[0].body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
    }

    @Test func noKeyMeansUnavailableAndSendsNothing() async throws {
        StubProtocol.reset([])
        let (backend, _) = rig(key: nil)
        #expect(await backend.availability == .unavailable(reason: "No Claude API key"))
        await #expect(throws: LLMError.unavailable(reason: "No Claude API key")) {
            try await backend.respond(instructions: "I", prompt: "P")
        }
        #expect(StubProtocol.seen.isEmpty)
    }

    @Test func aKeyMakesItAvailable() async {
        let (backend, _) = rig()
        #expect(await backend.availability == .available)
        #expect(backend.maxPromptCharacters == 600_000)
    }

    @Test func status401IsAKeyRejection() async {
        StubProtocol.reset([.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        let (backend, _) = rig()
        await #expect(throws: LLMError.unavailable(reason: "Claude key rejected")) {
            try await backend.respond(instructions: "I", prompt: "P")
        }
        #expect(StubProtocol.seen.count == 1)
    }

    @Test(arguments: [429, 529]) func busyRetriesOnceAfterRetryAfter(status: Int) async throws {
        StubProtocol.reset([
            .init(status: status, headers: ["retry-after": "7"], body: "{}"),
            .init(status: 200, body: ok),
        ])
        let (backend, sleeps) = rig()
        #expect(try await backend.respond(instructions: "I", prompt: "P") == "Hello there")
        #expect(StubProtocol.seen.count == 2)
        #expect(sleeps.values == [.seconds(7)])
    }

    @Test(arguments: [429, 529]) func busyTwiceFails(status: Int) async {
        StubProtocol.reset([
            .init(status: status, headers: ["retry-after": "2"], body: "{}"),
            .init(status: status, headers: ["retry-after": "2"], body: "{}"),
            .init(status: 200, body: ok),
        ])
        let (backend, sleeps) = rig()
        do {
            _ = try await backend.respond(instructions: "I", prompt: "P")
            Issue.record("expected a failure")
        } catch let LLMError.failed(message) {
            #expect(message.contains("\(status)"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(StubProtocol.seen.count == 2)
        #expect(sleeps.values == [.seconds(2)])
    }

    @Test func promptTooLongIsContextTooLong() async {
        StubProtocol.reset([.init(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#)])
        let (backend, _) = rig()
        await #expect(throws: LLMError.contextTooLong) { try await backend.respond(instructions: "I", prompt: "P") }
    }

    @Test func refusalIsAGuardrail() async {
        StubProtocol.reset([.init(status: 200, body: #"{"content":[],"stop_reason":"refusal"}"#)])
        let (backend, _) = rig()
        await #expect(throws: LLMError.guardrail) { try await backend.respond(instructions: "I", prompt: "P") }
    }

    @Test func emptyContentIsAnEmptyResponse() async {
        StubProtocol.reset([.init(status: 200, body: #"{"content":[],"stop_reason":"end_turn"}"#)])
        let (backend, _) = rig()
        await #expect(throws: LLMError.emptyResponse) { try await backend.respond(instructions: "I", prompt: "P") }
    }

    @Test func otherStatusesFailWithTheServerMessage() async {
        StubProtocol.reset([.init(status: 500, body: #"{"type":"error","error":{"type":"api_error","message":"boom"}}"#)])
        let (backend, _) = rig()
        do {
            _ = try await backend.respond(instructions: "I", prompt: "P")
            Issue.record("expected a failure")
        } catch let LLMError.failed(message) {
            #expect(message.contains("500") && message.contains("boom"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

final class SleepRecorder: Sendable {
    private let log = Mutex<[Duration]>([])
    var values: [Duration] { log.withLock { $0 } }
    func record(_ d: Duration) { log.withLock { $0.append(d) } }
}

@Suite struct InMemoryKeyStoreTests {
    @Test func savesAndDeletes() throws {
        let store = InMemoryAPIKeyStore()
        #expect(try store.apiKey() == nil)
        try store.save(apiKey: "k")
        #expect(try store.apiKey() == "k")
        try store.deleteKey()
        #expect(try store.apiKey() == nil)
    }
}
