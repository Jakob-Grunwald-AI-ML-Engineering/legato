import Foundation
import Testing
import LegatoClaude
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAgent

@Test func streamingFramesAndEarlyTargets() throws {
    // Framing and delta shapes documented by https://platform.claude.com/docs/en/build-with-claude/streaming
    // This is a docs example, not a captured live response.
    var parser = SSEParser()
    #expect(parser.consume(line: "event: content_block_delta") == nil)
    #expect(parser.consume(line: #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\\"from\\\":\\\"L12\\\","}}"#) == nil)
    #expect(parser.consume(line: "")?.event == "content_block_delta")
    #expect(PartialJSON.targets(in: #"{"from":"L12","to":"L15","lines":["unfinished"#) == ["L12", "L15"])
    #expect(PartialJSON.targets(in: #"{"from":"unfinished"#).isEmpty)
    #expect(DocPresenter.strip("Keep ⟨Claude|0.42⟩ here") == "Keep Claude here")
}

@Test func modelRequestsAndPrompts() throws {
    for model in ModelChoice.allCases {
        for live in [true, false] {
            let data = try AgentRunner.request(model: model, system: "instructions", messages: [], live: live)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            #expect(value["thinking"] == model.thinking)
            #expect(value["tool_choice"]?["type"] == .string("auto"))
            #expect(value["cache_control"]?["type"] == .string("ephemeral"))
            let tools = try #require(value["tools"]).decode([JSONValue].self)
            #expect(tools.allSatisfy { $0["strict"] == .bool(true) && $0["eager_input_streaming"] == .bool(true) })
            #expect(tools.contains { $0["name"] == .string("request_restructure") } == live)
        }
    }
    #expect(PromptLayers.build(mode: .email, personal: "Be direct", vocabulary: ["Kubernetes"]).contains("Kubernetes"))
    #expect(AgentRunner.shouldReseed(tokens: 50_001, idle: 0))
    #expect(AgentRunner.shouldReseed(tokens: 2, idle: 301))
    #expect(!AgentRunner.shouldReseed(tokens: 50_000, idle: 300))
}

@Test func toolTransactionConflictAndPin() async throws {
    let room = Room()
    _ = try await room.publishSegment(words: [Word(text: "helo", confidence: 0.42), Word(text: "world", confidence: 0.98)])
    let first = try #require(await room.documentSnapshot.lines.first)
    let executor = ToolExecutor(room: room)
    let input: JSONValue = .object(["line": .string(first.id), "old": .string("helo"), "new": .string("⟨hello|0.42⟩"), "version": .number(Double(first.version))])
    let stream = await room.subscribe(participant: .logger, channels: [.docOps])
    let result = await executor.execute(name: "replace_in_line", input: input, groupID: "turn", live: true)
    #expect(!result.isError)
    var iterator = stream.makeAsyncIterator()
    let transaction = try #require(await iterator.next()).payload.decode(Transaction.self)
    #expect(transaction.ops.count == 1)
    #expect(transaction.groupID == "turn")
    #expect(await room.documentSnapshot.lines.first?.words.last?.confidence == 0.98)
    let stale = await executor.execute(name: "replace_in_line", input: input, groupID: "turn", live: true)
    #expect(stale.isError && stale.content.contains("view"))
    let line = try #require(await room.documentSnapshot.lines.first)
    _ = try await room.applyDocument([.pinWord(lineID: line.id, wordID: line.words[0].id, text: "hello")], origin: .user, versions: [line.id: line.version])
    let pinned = try #require(await room.documentSnapshot.lines.first)
    let rejected = await executor.execute(name: "delete_lines", input: .object(["from": .string(pinned.id), "to": .string(pinned.id), "versions": .object([pinned.id: .number(Double(pinned.version))])]), groupID: "turn", live: true)
    #expect(rejected.isError)
}

@Test func triggerPolicies() async throws {
    let room = Room(clock: { 1 })
    let segment = try await room.publishSegment(words: [Word(text: "hello")])
    let hint = try await room.publish(channel: .hint, participant: .ui, payload: .null)
    var live = LiveAgentPolicy()
    #expect(live.begin() == nil)
    live.enqueue(segment); #expect(live.begin()?.count == 1)
    live.editing = ["L1"]
    let preempts = live.enqueue(hint, hintTargets: ["L1"]); #expect(preempts)
    live.enqueue(segment); #expect(live.begin() == nil)
    live.finish(); #expect(live.begin()?.first?.channel == .hint)
    var policy = RestructurePolicy()
    policy.segment(at: 0); policy.segment(at: 1)
    #expect(policy.begin(at: 3) == nil)
    #expect(policy.begin(at: 3.5) == false)
    policy.finalPass(); #expect(policy.begin(at: 5) == nil)
    policy.finish(); #expect(policy.begin(at: 5) == true)
    policy.finish(); policy.request(); #expect(policy.begin(at: 6) == false)
    policy.finish(); for _ in 0..<4 { policy.segment(at: 6) }; #expect(policy.begin(at: 6) == false)
}

import Synchronization
private final class ScriptedMessages: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let line: String
    init(line: String) { self.line = line }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let first = requests.withLock { values in values.append(request); return values.count == 1 }
        return AsyncThrowingStream { continuation in
            func emit(_ type: String, _ json: JSONValue) {
                let data = try! JSONEncoder().encode(json)
                continuation.yield(.init(event: type, data: String(decoding: data, as: UTF8.self)))
            }
            if first {
                emit("content_block_start", .object(["index": .number(0), "content_block": .object(["type": .string("tool_use"), "id": .string("tool1"), "name": .string("replace_in_line"), "input": .object(["line": .string(line), "old": .string("helo"), "new": .string("hello"), "version": .number(0)])])]))
            } else {
                emit("content_block_start", .object(["index": .number(0), "content_block": .object(["type": .string("text"), "text": .string("Done")])]))
            }
            emit("message_stop", .object(["type": .string("message_stop")]))
            continuation.finish()
        }
    }
}

@Test func runnerExecutesToolAndReturnsResult() async throws {
    let room = Room()
    _ = try await room.publishSegment(words: [Word(text: "helo")])
    let line = try #require(await room.documentSnapshot.lines.first)
    let client = ScriptedMessages(line: line.id)
    let runner = AgentRunner(room: room, client: client)
    await runner.start()
    _ = try await room.publish(channel: .userIntent, participant: .ui, payload: .string("Fix spelling"))
    for _ in 0..<100 {
        if client.requests.withLock({ $0.count >= 2 }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await room.documentSnapshot.text == "hello")
    let requests = client.requests.withLock { $0 }
    #expect(requests.count == 2)
    #expect(String(decoding: try #require(requests.last), as: UTF8.self).contains("tool_result"))
    _ = try await room.insert()
    await runner.stop()
}
