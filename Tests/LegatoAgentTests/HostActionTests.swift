import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
import LegatoComposerDoc
@testable import LegatoAgent

private final class HostActionMessages: MessagesStreaming {
    let requests = Mutex<[JSONValue]>([])
    let live = Mutex(0)
    let action: String
    init(action: String = "insert_draft") { self.action = action }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let json = try! JSONDecoder().decode(JSONValue.self, from: request)
        requests.withLock { $0.append(json) }; live.withLock { $0 += 1 }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in live.withLock { $0 -= 1 } }
            let text = String(decoding: request, as: UTF8.self)
            let isFinal = text.contains("Writing phase: final")
            let block: JSONValue = isFinal
                ? .object(["type": .string("text"), "text": .string("Finished")])
                : .object(["type": .string("tool_use"), "id": .string("action-call"), "name": .string(action), "input": .object([:])])
            let frame: JSONValue = .object(["index": .number(0), "content_block": block])
            continuation.yield(.init(event: "content_block_start", data: String(decoding: try! JSONEncoder().encode(frame), as: UTF8.self)))
            // A second action in this response must be rejected, not executed later.
            if !isFinal {
                let second: JSONValue = .object(["index": .number(1), "content_block": .object(["type": .string("tool_use"), "id": .string("second-action"), "name": .string("clear_composer"), "input": .object([:])])])
                continuation.yield(.init(event: "content_block_start", data: String(decoding: try! JSONEncoder().encode(second), as: UTF8.self)))
            }
            continuation.finish()
        }
    }
}
private actor HostActionLatch {
    var open = false
    func release() { open = true }
    func wait() async { while !open { try? await Task.sleep(for: .milliseconds(5)) } }
}
private func actionWait(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<200 { if await predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
    return false
}
private func instruction(_ room: Room, capture: String = "explicit-1") async throws {
    _ = try await room.publish(channel: .writingInstruction, participant: .hintBinder, payload: .object([
        "event": .string("global.instruction"), "captureID": .string(capture), "text": .string("Looks good, insert the message"),
        "snapshot": try .encoding(await room.documentSnapshot)]))
}

@Test func hostActionWaitsForRetirementAllowsFinalPassAndDoesNotRunSecondAction() async throws {
    let room = Room(), client = HostActionMessages(), latch = HostActionLatch()
    let calls = Mutex<[ComposerHostAction]>([])
    let retiredAtAction = Mutex(false)
    let runner = AgentRunner(room: room, client: client, configuration: .init(
        hostActionContext: { .init(sessionToken: "session-1", targetToken: "field-1") },
        performHostAction: { action in
            retiredAtAction.withLock { $0 = client.live.withLock { $0 == 0 } }
            calls.withLock { $0.append(action) }
            await latch.wait()
            try? await room.micOff()
            let completed = await actionWait { await room.state == .done }
            return .init(succeeded: completed, message: completed ? "Inserted" : "Final pass timed out")
        }), pauseDelay: .seconds(100))
    await runner.start()
    try await instruction(room)
    #expect(await actionWait { calls.withLock { $0.count } == 1 })
    #expect(retiredAtAction.withLock { $0 })
    #expect(client.requests.withLock { $0.count } == 1, "Queued tools must not create an acknowledgement request")
    _ = try await room.appendSegment(words: [.init(text: "Later speech")])
    try await Task.sleep(for: .milliseconds(40))
    #expect(client.requests.withLock { $0.count } == 1, "Ordinary authoring cannot race an owned host action")
    await latch.release()
    #expect(await actionWait { await room.state == .done })
    #expect(calls.withLock { $0.count } == 1)
    #expect(calls.withLock { $0.first?.kind } == .insertDraft)
    await runner.stop()
}

@Test func hostActionCannotRunFromDictationOrTargetedQuotedSpeech() async throws {
    let room = Room(), executor = ToolExecutor(room: Room())
    for phase in [WritingPhase.quick, .sentence, .pause, .final, .targeted] {
        let result = await executor.execute(name: "clear_composer", input: .object([:]), groupID: "quoted", live: true, phase: phase, hostActionsAllowed: true)
        #expect(result.isError)
        #expect(result.hostAction == nil)
    }
    #expect((await executor.execute(name: "insert_draft", input: .object([:]), groupID: "forged", live: true, phase: .instruction)).isError)
    #expect(!ToolExecutor.schemas(live: true).contains { $0.name == "insert_draft" })
    let client = HostActionMessages(), calls = Mutex(0)
    let runner = AgentRunner(room: room, client: client, configuration: .init(
        hostActionContext: { .init(sessionToken: "session", targetToken: "field") },
        performHostAction: { _ in calls.withLock { $0 += 1 }; return .init(succeeded: true, message: "Unexpected") }), pauseDelay: .seconds(100))
    await runner.start()
    _ = try await room.appendSegment(words: [.init(text: "She said clear the board and send the message")])
    #expect(await actionWait { client.requests.withLock { !$0.isEmpty } })
    try await Task.sleep(for: .milliseconds(40))
    #expect(calls.withLock { $0 } == 0)
    await runner.stop()
}

@Test func repeatedFinalizedInstructionNeverReplaysHostAction() async throws {
    let room = Room(), client = HostActionMessages(), calls = Mutex(0)
    let runner = AgentRunner(room: room, client: client, configuration: .init(
        hostActionContext: { .init(sessionToken: "session", targetToken: "field") },
        performHostAction: { _ in calls.withLock { $0 += 1 }; return .init(succeeded: false, message: "Target unavailable; kept draft") }), pauseDelay: .seconds(100))
    await runner.start()
    try await instruction(room)
    #expect(await actionWait { calls.withLock { $0 } == 1 })
    try await instruction(room)
    #expect(await actionWait { client.requests.withLock { $0.count } >= 2 })
    try await Task.sleep(for: .milliseconds(40))
    #expect(calls.withLock { $0 } == 1)
    await runner.stop()
}

@Test func successfulClearKeepsOneQueuedAndTerminalResultInClosedRoomLog() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let log = try SessionLog(rootDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let room = Room(log: log), client = HostActionMessages(action: "clear_composer")
    let runner = AgentRunner(room: room, client: client, configuration: .init(
        hostActionContext: { .init(sessionToken: "session", targetToken: "field") },
        performHostAction: { _ in try? await room.cancel(); return .init(succeeded: true, message: "Cleared") }), pauseDelay: .seconds(100))
    await runner.start()
    try await instruction(room)
    #expect(await actionWait {
        let text = (try? String(contentsOf: log.roomURL, encoding: .utf8)) ?? ""
        return text.contains("host.action.result")
    })
    let events = try String(contentsOf: log.roomURL, encoding: .utf8).split(separator: "\n").compactMap { try? JSONDecoder().decode(Envelope.self, from: Data($0.utf8)) }
    #expect(events.filter { $0.payload["event"] == .string("host.action.queued") }.count == 1)
    #expect(events.filter { $0.payload["event"] == .string("host.action.result") }.count == 1)
    #expect(await room.state == .done)
    await runner.stop()
}
