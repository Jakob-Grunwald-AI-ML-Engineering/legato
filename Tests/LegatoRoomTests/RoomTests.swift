import Foundation
import Testing
import LegatoComposerDoc
@testable import LegatoRoom

@Test func totalOrderAndSubscriptions() async throws {
    let room = Room(clock: { 42 })
    let stream = await room.subscribe(participant: .liveAgent, channels: [.hint])
    var iterator = stream.makeAsyncIterator()
    _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .string("tail"))
    let sent = try await room.publish(channel: .hint, participant: .ui, payload: .string("fix"), tOrigin: 7)
    let received = await iterator.next()
    #expect(received == sent)
    #expect(sent.seq == 2)
    #expect(sent.tMono == 42)
    #expect(sent.tOrigin == 7)
}

@Test func concurrentPublishHasTotalOrder() async throws {
    let room = Room()
    let values = try await withThrowingTaskGroup(of: Int64.self) { group in
        for _ in 0..<100 {
            group.addTask { try await room.publish(channel: .hint, participant: .ui, payload: .null).seq }
        }
        var seqs: [Int64] = []
        for try await seq in group { seqs.append(seq) }
        return seqs.sorted()
    }
    #expect(values == Array(1...100).map(Int64.init))
}

@Test func segmentsPublishWordsWithoutDocumentMutation() async throws {
    let room = Room()
    await #expect(throws: RoomError.retiredDocumentChannel) {
        try await room.publish(channel: .docOps, participant: .document, payload: .null)
    }
    let stream = await room.subscribe(participant: .logger, channels: [.asrSegment])
    var events = stream.makeAsyncIterator()
    let words = [Word(text: "Hello", confidence: 0.42, language: "en")]
    let sent = try await room.publishSegment(words: words)
    #expect(await events.next() == sent)
    #expect(try sent.payload["words"]?.decode([Word].self) == words)
    await #expect(throws: RoomError.invalidSegment) { try await room.publishSegment(words: []) }
}

@Test func slowUISubscriberDropsOnlyItsOwnOldEvents() async throws {
    let room = Room()
    let ui = await room.subscribe(participant: .ui, channels: [.hint], buffering: .newest(1))
    let agent = await room.subscribe(participant: .liveAgent, channels: [.hint])
    for number in 1...200 { _ = try await room.publish(channel: .hint, participant: .ui, payload: .number(Double(number))) }
    var uiIterator = ui.makeAsyncIterator()
    var agentIterator = agent.makeAsyncIterator()
    #expect(await uiIterator.next()?.seq == 200)
    for number in 1...200 { #expect(await agentIterator.next()?.seq == Int64(number)) }
}

@Test func lifecycleDrainsTranscriptionThenFinishes() async throws {
    let room = Room(clock: { 55 })
    try await room.micOff(transcriberDraining: true)
    #expect(await room.state == .trailing)
    await room.finishTranscription()
    #expect(await room.state == .finalPass)
    try await room.finishFinalPass()
    #expect(await room.state == .done)
    await #expect(throws: RoomError.sessionEnded) { try await room.publishSegment(words: [Word(text: "late")]) }
}

@Test func interceptedSegmentMustBeAcknowledgedBeforeDrainCompletes() async throws {
    let room = Room(segmentRouting: .intercepted)
    let event = try await room.publishSegment(words: [Word(text: "normal")])
    try await room.micOff()
    #expect(await room.state == .trailing)
    await room.resolveSegment("unknown")
    #expect(await room.state == .trailing)
    await room.resolveSegment(event.id)
    #expect(await room.state == .finalPass)
}

@Test func loggerRoundTripsAndRedactsSecrets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try SessionLog(rootDirectory: root, sessionID: "test", secrets: ["private-test-key"])
    let room = Room(log: log, clock: { 3 })
    let envelope = try await room.publish(channel: .hint, participant: .ui, payload: .object(["text": .string("hello")]))
    let raw = try String(contentsOf: log.roomURL, encoding: .utf8)
    #expect(try JSONDecoder().decode(Envelope.self, from: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) == envelope)
    _ = try await room.publish(channel: .agentStatus, participant: .liveAgent, payload: .object(["Authorization": .string("Bearer private-test-key"), "text": .string("private-test-key")]))
    let all = try String(contentsOf: log.roomURL, encoding: .utf8)
    #expect(!all.contains("private-test-key"))
    #expect(all.contains("[REDACTED]"))
    try await room.cancel()
    #expect(log.audioURL.lastPathComponent == "audio.m4a")
}

@Test func aRoomThatSkipsTheTailLogsTheRestOfTheSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try SessionLog(rootDirectory: root)
    let room = Room(log: log, segmentRouting: .intercepted, logsTail: false)
    let tails = await room.subscribe(participant: .logger, channels: [.asrRawTail], buffering: .unbounded)
    var received = tails.makeAsyncIterator()
    _ = try await room.publish(channel: .asrTail, participant: .transcriber, payload: .object(["text": .string("partial")]))
    _ = try await room.publish(channel: .session, participant: .transcriber, payload: .object(["event": .string("asr.started")]))
    #expect(await received.next()?.payload["text"] == .string("partial"), "subscribers still hear the tail")
    let raw = try String(contentsOf: log.roomURL, encoding: .utf8)
    #expect(raw.contains("asr.started") && !raw.contains("partial") && !raw.contains("asr.raw-tail"))
}

@Test func finalPassWaitsForTranscriber() async throws {
    let room = Room(clock: { 77 })
    let events = await room.subscribe(participant: .logger, channels: [.session])
    var iterator = events.makeAsyncIterator()
    try await room.micOff(transcriberDraining: true)
    #expect(await room.state == .trailing)
    _ = try await room.publishSegment(words: [Word(text: "last")])
    await room.finishTranscription()
    #expect(await room.state == .finalPass)
    try await room.finishFinalPass()
    #expect(await room.state == .done)
    var names: [JSONValue] = []
    while let event = await iterator.next() {
        #expect(event.tMono == 77)
        if let name = event.payload["event"] { names.append(name) }
    }
    #expect(names == [.string("mic.off"), .string("final.pass"), .string("cancel.work"), .string("done")])
}

@Test func cancelWorksAtEveryState() async throws {
    for desiredState in [SessionState.listening, .trailing, .finalPass, .done] {
        let room = Room()
        _ = try await room.publishSegment(words: [Word(text: "current")])
        if desiredState == .trailing { try await room.micOff(transcriberDraining: true) }
        else if desiredState == .finalPass || desiredState == .done {
            try await room.micOff()
            if desiredState == .done { try await room.finishFinalPass() }
        }
        #expect(await room.state == desiredState)
        try await room.cancel()
        #expect(await room.state == .done)
        await #expect(throws: RoomError.sessionEnded) { try await room.publishSegment(words: [Word(text: "late")]) }
    }
}

@Test func loggerCapturesEveryChannelAndLifecycleEnvelope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try SessionLog(rootDirectory: root)
    let room = Room(log: log)
    let stream = await room.subscribe(participant: .logger, channels: Set(Channel.allCases))
    for channel in Channel.allCases where !channel.isDocument && channel != .asrSegment {
        _ = try await room.publish(channel: channel, participant: .ui,
            payload: .object(["nested": .array([.null, .bool(true), .number(0.42), .string("ä\nline")])]))
    }
    _ = try await room.publishSegment(words: [Word(text: "content")])
    try await room.cancel()
    var delivered: [Envelope] = []
    for await event in stream { delivered.append(event) }
    let raw = try String(contentsOf: log.roomURL, encoding: .utf8)
    let replayed = try raw.split(separator: "\n").map { try JSONDecoder().decode(Envelope.self, from: Data($0.utf8)) }
    #expect(replayed == delivered)
    #expect(Set(replayed.map(\.channel)) == Set(Channel.allCases.filter { !$0.isDocument }))
    #expect(await room.loggingError == nil)
}
