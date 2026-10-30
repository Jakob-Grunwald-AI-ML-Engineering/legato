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

@Test func documentCapabilityAndSegmentAppend() async throws {
    let room = Room()
    await #expect(throws: RoomError.documentChannelRequiresCapability) {
        try await room.publish(channel: .docOps, participant: .document, payload: .null)
    }
    _ = try await room.publishSegment(words: [Word(text: "Hello")])
    _ = try await room.publishSegment(words: [Word(text: "world")])
    let snapshot = await room.documentSnapshot
    #expect(snapshot.lines.map(\.text) == ["Hello", "world"])
    var other = ComposerDocument()
    _ = try other.appendSegment(words: [Word(text: "owned")])
    let published = try await room.publishDocument(other.snapshotPublication)
    #expect(published.channel == .docSnapshot)
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

@Test func lifecycleDrainsThenFinalPassAndImmediateInsert() async throws {
    let room = Room(clock: { 55 })
    await room.setAgentBusy(.liveAgent, busy: true)
    try await room.micOff()
    #expect(await room.state == .trailing)
    await room.setAgentBusy(.liveAgent, busy: false)
    #expect(await room.state == .finalPass)
    let snapshot = try await room.insert()
    #expect(snapshot.text == "")
    #expect(await room.state == .done)
    await #expect(throws: RoomError.sessionEnded) {
        try await room.publishSegment(words: [Word(text: "late")])
    }
}

@Test func interceptedSegmentDoesNotAppendUntilReleased() async throws {
    let room = Room(segmentRouting: .intercepted)
    let words = [Word(text: "normal")]
    let event = try await room.publishSegment(words: words)
    #expect(await room.documentSnapshot.lines.isEmpty)
    _ = try await room.appendSegment(words: words, causedBy: event.id)
    #expect(await room.documentSnapshot.text == "normal")
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
    _ = try await room.insert()
    #expect(FileManager.default.fileExists(atPath: log.finalURL.path))
    #expect(log.audioURL.lastPathComponent == "audio.m4a")
}
