import Foundation
import Testing
import LegatoRoom
@testable import LegatoAgent

@Test func autoGuidanceLoaderReturnsExistingEmailSkillWithoutEditing() async {
    let room = Room()
    let before = await room.documentSnapshot
    for live in [true, false] {
        let result = await ToolExecutor(room: room).execute(name: "load_writing_guidance",
            input: .object(["mode": .string("email")]), groupID: "guidance", live: live)
        #expect(!result.isError)
        #expect(result.content == "Compose a clear email with appropriate greeting, paragraphs and closing only when supported by the user input.\n")
        #expect(result.mode == nil)
        #expect(await room.documentSnapshot == before)
    }
    for unsupported in ["auto", "../../base", "missing"] {
        let result = await ToolExecutor(room: room).execute(name: "load_writing_guidance",
            input: .object(["mode": .string(unsupported)]), groupID: "guidance", live: true)
        #expect(result.isError)
    }
}

@Test func autoGuidanceSchemaIsClosedAndManualModesKeepTheirTools() throws {
    #expect(AgentConfiguration().mode == .message)
    for live in [true, false] {
        let manual = ToolExecutor.schemas(live: live)
        #expect(manual.contains { $0.name == "set_mode" })
        #expect(!manual.contains { $0.name == "load_writing_guidance" })
        let tools = ToolExecutor.schemas(live: live, mode: .auto)
        let loader = try #require(tools.first { $0.name == "load_writing_guidance" })
        let schema = try JSONValue.encoding(loader)
        #expect(schema["input_schema"]?["properties"]?["mode"]?["enum"] == .array(["message", "email", "prompt", "note"].map(JSONValue.string)))
        #expect(!tools.contains { $0.name == "set_mode" })
        #expect(tools.contains { $0.name == "request_restructure" } == live)
    }
}

import Synchronization
import LegatoClaude
import LegatoComposerDoc

private final class AutoSkillMessages: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let line: String
    init(line: String) { self.line = line }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let step = requests.withLock { $0.append(request); return $0.count }
        return AsyncThrowingStream { continuation in
            let block: JSONValue
            switch step {
            case 1:
                block = .object(["type": .string("tool_use"), "id": .string("guide"),
                    "name": .string("load_writing_guidance"), "input": .object(["mode": .string("email")])])
            case 2:
                block = .object(["type": .string("tool_use"), "id": .string("write"),
                    "name": .string("replace_in_line"), "input": .object([
                        "line": .string(line), "old": .string("Write an email to Morgan"),
                        "new": .string("Hi Morgan,"), "version": .number(0)])])
            default: block = .object(["type": .string("text"), "text": .string("Done")])
            }
            let value: JSONValue = .object(["index": .number(0), "content_block": block])
            continuation.yield(.init(event: "content_block_start", data: String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)))
            continuation.yield(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
            continuation.finish()
        }
    }
}

@Test func autoRunnerLoadsSkillThroughToolResultAndKeepsSystemPrefix() async throws {
    let room = Room()
    _ = try await room.publishSegment(words: "Write an email to Morgan".split(separator: " ").map { Word(text: String($0)) })
    let line = try #require(await room.documentSnapshot.lines.first)
    let client = AutoSkillMessages(line: line.id)
    let runner = AgentRunner(room: room, client: client, configuration: .init(mode: .auto))
    await runner.start()
    _ = try await room.publish(channel: .userIntent, participant: .ui, payload: .string("Compose the email"))
    for _ in 0..<100 {
        if client.requests.withLock({ $0.count >= 3 }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let calls = try client.requests.withLock { try $0.map { try JSONDecoder().decode(JSONValue.self, from: $0) } }
    #expect(calls.count == 3)
    if calls.count == 3 {
        #expect(calls[0]["system"] == calls[1]["system"])
        #expect(calls[1]["system"] == calls[2]["system"])
        let secondMessages = try #require(calls[1]["messages"]).decode([JSONValue].self)
        let results = try #require(secondMessages.last?["content"]).decode([JSONValue].self)
        let result = try #require(results.first)
        #expect(result["type"] == .string("tool_result"))
        #expect(result["content"] == .string(try PromptLayers.writingGuidance(for: .email)))
        #expect(result["is_error"] == .bool(false))
    }
    #expect(await room.documentSnapshot.text == "Hi Morgan,")
    await runner.stop()
}
