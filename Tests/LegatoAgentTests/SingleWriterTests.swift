import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoComposerDoc
import LegatoRoom
@testable import LegatoAgent

private final class WriterMessages: MessagesStreaming {
    struct Call: Sendable {
        let model: String
        let phase: String
        let request: Data
        let continuation: AsyncThrowingStream<SSEEvent, any Error>.Continuation
    }
    struct State {
        var calls: [Call] = []
        var active: Set<Int> = []
        var maxActive = 0
        var canceledPhases: [String] = []
    }
    let state = Mutex(State())
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        let json = try! JSONDecoder().decode(JSONValue.self, from: request)
        let model: String
        if case .string(let s) = json["model"] { model = s } else { model = "missing" }
        let messages = (try? json["messages"]?.decode([JSONValue].self)) ?? []
        let text = messages.reversed().compactMap { message -> String? in
            if case .string(let content) = message["content"], content.contains("Writing phase:") { return content }; return nil
        }.first ?? ""
        let phase = ["targeted", "final", "pause", "sentence", "quick"].first { text.contains("Writing phase: \($0)") } ?? "legacy"
        let pair = AsyncThrowingStream<SSEEvent, any Error>.makeStream()
        let id = state.withLock { s in
            let id = s.calls.count
            s.calls.append(.init(model: model, phase: phase, request: request, continuation: pair.continuation))
            s.active.insert(id); s.maxActive = max(s.maxActive, s.active.count)
            return id
        }
        pair.continuation.onTermination = { [self] reason in
            state.withLock { s in
                s.active.remove(id)
                if case .cancelled = reason { s.canceledPhases.append(phase) }
            }
        }
        return pair.stream
    }
    func finish(_ index: Int) {
        let c = state.withLock { $0.calls[index].continuation }
        c.yield(.init(event: "content_block_start", data: #"{"index":0,"content_block":{"type":"text","text":"No edit needed."}}"#))
        c.yield(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
        c.finish()
    }
    func finishTool(_ index: Int, name: String, input: JSONValue) throws {
        let c = state.withLock { $0.calls[index].continuation }
        let block: JSONValue = .object(["index": .number(0), "content_block": .object(["type": .string("tool_use"), "id": .string("tool-\(index)"), "name": .string(name), "input": input])])
        c.yield(.init(event: "content_block_start", data: String(decoding: try JSONEncoder().encode(block), as: UTF8.self)))
        c.yield(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
        c.finish()
    }
    func calls() -> [Call] { state.withLock { $0.calls } }
}
private func waitForWriter(_ condition: () async -> Bool) async throws -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test func oneWriterUsesSelectedModelForQuickPauseAndFinalWithoutConcurrentRequests() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client,
        configuration: .init(liveModel: .haiku), pauseDelay: .milliseconds(80))
    await runner.start()
    for n in 1...4 { _ = try await room.publishSegment(words: [.init(text: "Fact \(n)")]) }
    #expect(try await waitForWriter { client.calls().count >= 1 })
    try await Task.sleep(for: .milliseconds(30))
    #expect(client.state.withLock { $0.maxActive } == 1)
    #expect(client.calls().allSatisfy { $0.model == ModelChoice.haiku.rawValue })
    // Drain batched quick work, then exactly one pause pass is eligible.
    for _ in 0..<10 {
        let calls = client.calls()
        if calls.last?.phase == "pause" { break }
        for i in client.state.withLock({ $0.active.sorted() }) { client.finish(i) }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(try await waitForWriter { client.calls().last?.phase == "pause" })
    for i in client.state.withLock({ $0.active.sorted() }) { client.finish(i) }
    try await room.micOff()
    #expect(try await waitForWriter { client.calls().last?.phase == "final" })
    let final = try #require(client.calls().last)
    #expect(final.model == ModelChoice.haiku.rawValue)
    #expect(String(decoding: final.request, as: UTF8.self).contains("No edit needed."), "Final uses the existing writer conversation")
    for i in client.state.withLock({ $0.active.sorted() }) { client.finish(i) }
    #expect(try await waitForWriter { await room.state == .done })
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}

@Test func continuedSpeechDefersAndPreemptsPauseWithoutASecondWriter() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, pauseDelay: .milliseconds(500))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "A draft")])
    #expect(try await waitForWriter { client.calls().count == 1 })
    client.finish(0)
    for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(40))
        _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("continuing speech")]))
    }
    #expect(!client.calls().contains { $0.phase == "pause" })
    #expect(try await waitForWriter { client.calls().last?.phase == "pause" })
    _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("new speech")]))
    #expect(try await waitForWriter { client.state.withLock { $0.canceledPhases.contains("pause") } })
    _ = try await room.publishSegment(words: [.init(text: "Another fact")])
    #expect(try await waitForWriter { client.calls().last?.phase == "quick" })
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}

@Test func quickPassAllowsSpellingButDefersBroadEditsAndTargetedPassRetainsThem() async throws {
    let room = Room()
    _ = try await room.publishSegment(words: [.init(text: "helo")])
    _ = try await room.publishSegment(words: [.init(text: "world")])
    let first = try #require(await room.documentSnapshot.lines.first)
    let executor = ToolExecutor(room: room)
    let spelling: JSONValue = .object(["line": .string(first.id), "old": .string("helo"), "new": .string("hello"), "version": .number(0)])
    #expect(!(await executor.execute(name: "replace_in_line", input: spelling, groupID: "quick", live: true, phase: .quick)).isError)
    let before = await room.documentSnapshot
    let last = try #require(before.lines.last)
    let replacement: JSONValue = .object(["from": .string(first.id), "to": .string(last.id), "lines": .array([.string("A targeted replacement")]),
        "versions": .array(before.lines.map { .object(["line": .string($0.id), "version": .number(Double($0.version))]) })])
    #expect((await executor.execute(name: "replace_lines", input: replacement, groupID: "quick", live: true, phase: .quick)).isError)
    #expect(await room.documentSnapshot == before)
    #expect(!(await executor.execute(name: "replace_lines", input: replacement, groupID: "targeted", live: true, phase: .targeted)).isError)
    #expect(await room.documentSnapshot.text == "A targeted replacement")
}


@Test func defaultWriterComposesAfterOneSecondQuietWithoutStopping() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client)
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "Some rough notes")])
    #expect(try await waitForWriter { client.calls().count == 1 })
    client.finish(0)
    // Continued partial speech must reset the actual quiet clock.
    try await Task.sleep(for: .milliseconds(600))
    _ = try await room.publish(channel: .asrTail, participant: .transcriber,
        payload: .object(["text": .string("still speaking")]))
    try await Task.sleep(for: .milliseconds(600))
    #expect(!client.calls().contains { $0.phase == "pause" })
    try await Task.sleep(for: .milliseconds(650))
    #expect(client.calls().last?.phase == "pause",
        "A short natural pause should allow composing without waiting 2.5 seconds or Stop")
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}

@Test func quietQueuedContentComposesInNextTurnInsteadOfAnotherQuickRoundTrip() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, pauseDelay: .milliseconds(80))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "First rough thought")])
    #expect(try await waitForWriter { client.calls().count == 1 })
    _ = try await room.publishSegment(words: [.init(text: "Second rough thought")])
    try await Task.sleep(for: .milliseconds(140))
    #expect(client.calls().count == 1)
    client.finish(0)
    #expect(try await waitForWriter { client.calls().count == 2 })
    let next = try #require(client.calls().last)
    #expect(next.phase == "pause", "Quiet queued content needs full composing tools immediately")
    #expect(String(decoding: next.request, as: UTF8.self).contains("Second rough thought"))
    client.finish(1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(client.calls().count == 2, "The folded composing turn consumes the quiet deadline")
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}


@Test func targetedCorrectionKeepsPriorityWhenOrdinaryContentIsQuiet() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, pauseDelay: .milliseconds(80))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "First rough thought")])
    #expect(try await waitForWriter { client.calls().count == 1 })
    _ = try await room.publishSegment(words: [.init(text: "Second rough thought")])
    _ = try await room.publish(channel: .hint, participant: .hintBinder,
        payload: .object(["instruction": .string("Correct the selected name")]))
    try await Task.sleep(for: .milliseconds(140))
    client.finish(0)
    #expect(try await waitForWriter { client.calls().count == 2 })
    #expect(client.calls().last?.phase == "targeted")
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}


@Test func completedSentenceComposesThroughContinuedSpeechAndCoalescesFollowingInput() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, configuration: .init(mode: .prompt), pauseDelay: .seconds(10))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "Um improve editing responsiveness.")])
    #expect(try await waitForWriter { client.calls().first?.phase == "sentence" })
    for _ in 0..<3 {
        _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("I am still speaking")]))
        _ = try await room.publishSegment(words: [.init(text: "Another thought.")])
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(client.calls().count == 1)
    #expect(client.state.withLock { $0.canceledPhases.isEmpty })
    client.finish(0)
    #expect(try await waitForWriter { client.calls().count == 2 })
    #expect(client.calls().last?.phase == "sentence")
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}

@Test func punctuationlessSpeechGetsBoundedAuthoringProgress() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, pauseDelay: .seconds(10))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "first unpunctuated chunk")])
    #expect(try await waitForWriter { client.calls().first?.phase == "quick" })
    _ = try await room.publishSegment(words: [.init(text: "second unpunctuated chunk")])
    client.finish(0)
    #expect(try await waitForWriter { client.calls().last?.phase == "sentence" })
    await runner.stop()
}

@Test func sentenceEditsCannotConsumeNewSpeechAndKeepTheirOwnReplacementInScope() async throws {
    let room = Room()
    _ = try await room.publishSegment(words: [.init(text: "Um improve editing.")])
    let first = try #require(await room.documentSnapshot.lines.first)
    let scope: Set<String> = [first.id]
    _ = try await room.publishSegment(words: [.init(text: "A later fact.")])
    let last = try #require(await room.documentSnapshot.lines.last)
    let executor = ToolExecutor(room: room)
    func input(_ to: String, _ versions: [Line]) -> JSONValue {
        .object(["from": .string(first.id), "to": .string(to), "lines": .array([.string("Improve editing responsiveness.")]),
            "versions": .array(versions.map { .object(["line": .string($0.id), "version": .number(Double($0.version))]) })])
    }
    #expect((await executor.execute(name: "replace_lines", input: input(last.id, [first, last]), groupID: "sentence", live: true, phase: .sentence, allowedLineIDs: scope)).isError)
    let result = await executor.execute(name: "replace_lines", input: input(first.id, [first]), groupID: "sentence", live: true, phase: .sentence, allowedLineIDs: scope)
    #expect(!result.isError)
    #expect(result.createdLineIDs.count == 1)
    #expect(!result.createdLineIDs.contains(last.id))
    #expect(await room.documentSnapshot.lines.last == last)
}


@Test func semanticDirectiveEscalatesToSameWriterWithoutWaitingForQuiet() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, pauseDelay: .seconds(10))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "make it shorter")])
    #expect(try await waitForWriter { client.calls().first?.phase == "quick" })
    try client.finishTool(0, name: "request_compose", input: .object(["reason": .string("The user asked to shorten the existing draft")]))
    #expect(try await waitForWriter { client.calls().count == 2 })
    #expect(client.calls().last?.phase == "sentence")
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}

@Test func sentenceAppliesAuthoredPromptToolResultBeforeStopWhileNewSpeechArrives() async throws {
    let room = Room(), client = WriterMessages()
    let runner = AgentRunner(room: room, client: client, configuration: .init(mode: .prompt), pauseDelay: .seconds(10))
    await runner.start()
    _ = try await room.publishSegment(words: [.init(text: "Um, sometimes the keyboard just disappears and iOS shows the native keyboard. I switch back and my session is still running. I do not know why. Okay, rewrite this into a nice prompt, please.")])
    #expect(try await waitForWriter { client.calls().first?.phase == "sentence" })
    let first = try #require(await room.documentSnapshot.lines.first)
    _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("another thought still in progress")]))
    _ = try await room.publishSegment(words: [.init(text: "Preserve the original details.")])
    let later = try #require(await room.documentSnapshot.lines.last)
    try client.finishTool(0, name: "replace_lines", input: .object(["from": .string(first.id), "to": .string(first.id), "lines": .array([.string("Investigate why the Legato keyboard sometimes disappears and iOS shows the native keyboard, while switching back reveals the session is still running.")]), "versions": .array([.object(["line": .string(first.id), "version": .number(Double(first.version))])])]))
    #expect(try await waitForWriter { await room.documentSnapshot.lines.first?.text == "Investigate why the Legato keyboard sometimes disappears and iOS shows the native keyboard, while switching back reveals the session is still running." })
    #expect(await room.documentSnapshot.lines.last == later)
    #expect(await room.state == .listening)
    #expect(client.state.withLock { $0.maxActive } == 1)
    await runner.stop()
}
