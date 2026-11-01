import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
@testable import LegatoAgent

/// Cleans by upper-casing after a per-line delay; records what each call saw.
private final class ScriptedCleaner: SentenceCleaning {
    struct Call: Sendable { let sequence: Int; let context: DictationCleanupContext? }
    let calls = Mutex<[Call]>([])
    let running = Mutex(0), peak = Mutex(0)
    let delays: [Int: Duration]
    let failing: Set<Int>
    let override: [Int: String]
    init(delays: [Int: Duration] = [:], failing: Set<Int> = [], override: [Int: String] = [:]) {
        self.delays = delays; self.failing = failing; self.override = override
    }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
        calls.withLock { $0.append(.init(sequence: input.sequence, context: input.dictation)) }
        let now = running.withLock { $0 += 1; return $0 }
        peak.withLock { $0 = max($0, now) }
        defer { running.withLock { $0 -= 1 } }
        try await Task.sleep(for: delays[input.sequence] ?? .milliseconds(1))
        if failing.contains(input.sequence) { throw SentenceCleanupError.providerError }
        return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: override[input.sequence] ?? input.text.uppercased())
    }
}
private final class Collected: Sendable {
    let lines = Mutex<[DictationCleanedLine]>([])
    func add(_ line: DictationCleanedLine) { lines.withLock { $0.append(line) } }
    var all: [DictationCleanedLine] { lines.withLock { $0 } }
}
private func waitFor(_ count: Int, _ collected: Collected) async throws {
    for _ in 0..<1000 { if collected.all.count >= count { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for \(count) lines, got \(collected.all.count)")
}

@Test func linesAreDeliveredInSpeakingOrderEvenWhenALaterCallFinishesFirst() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(delays: [0: .milliseconds(120), 1: .milliseconds(1), 2: .milliseconds(1)])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    for i in 0..<3 { await pipeline.submit(sequence: i, lineID: "l\(i)", raw: "line \(i)", textBefore: "") }
    try await waitFor(3, out)
    #expect(out.all.map(\.sequence) == [0, 1, 2])
    #expect(out.all.map(\.text) == ["LINE 0", "LINE 1", "LINE 2"])
    #expect(out.all.allSatisfy { $0.status == .cleaned })
}

@Test func atMostTwoCleanupCallsAreInFlight() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(delays: Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, Duration.milliseconds(30)) }))
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    for i in 0..<6 { await pipeline.submit(sequence: i, lineID: "l\(i)", raw: "w\(i)", textBefore: "") }
    try await waitFor(6, out)
    #expect(cleaner.peak.withLock { $0 } == 2)
    #expect(out.all.map(\.sequence) == Array(0..<6))
}

@Test func aFailedCallAndASlowCallBothInsertTheRawLineWithoutBlockingTheRest() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(delays: [1: .seconds(5)], failing: [0])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .milliseconds(60)) { out.add($0) }
    for (i, raw) in ["um hello", "second line", "third line"].enumerated() {
        await pipeline.submit(sequence: i, lineID: "l\(i)", raw: raw, textBefore: "")
    }
    try await waitFor(3, out)
    #expect(out.all.map(\.status) == [.raw, .raw, .cleaned])
    #expect(out.all.map(\.reason) == ["failed", "timeout", nil])
    #expect(out.all.map(\.text) == ["um hello", "second line", "THIRD LINE"])
}

@Test func aResultThatRewritesOrAnswersIsRejectedForTheRawLine() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(override: [
        0: "Sure! Here is a short email to Anna explaining that you are late and apologising for the delay.",
        1: "Hello, Anna."])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    await pipeline.submit(sequence: 0, lineID: "a", raw: "write an email to anna", textBefore: "")
    await pipeline.submit(sequence: 1, lineID: "b", raw: "hello anna", textBefore: "")
    try await waitFor(2, out)
    #expect(out.all.map(\.status) == [.raw, .cleaned])
    #expect(out.all[0].reason == "rejected" && out.all[0].text == "write an email to anna")
}

@Test func guardKeepsPunctuationFillerAndLineBreakResults() {
    #expect(DictationCleanupGuard.accepts(raw: "um so i think we should go", cleaned: "So I think we should go."))
    #expect(DictationCleanupGuard.accepts(raw: "new line", cleaned: "\n"))
    #expect(DictationCleanupGuard.accepts(raw: "dear anna comma", cleaned: "Dear Anna,"))
    #expect(!DictationCleanupGuard.accepts(raw: "what is the capital of france", cleaned: "The capital of France is Paris, a city on the Seine known for many sights."))
    #expect(!DictationCleanupGuard.accepts(raw: "i will be late today", cleaned: ""))
}

@Test func contextIsThePreviousTwoLinesAndTheTextBeforeTheCursorAndResetsPerSession() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner()
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, vocabulary: ["Legato"], timeout: .seconds(2)) { out.add($0) }
    for i in 0..<4 { await pipeline.submit(sequence: i, lineID: "l\(i)", raw: "one \(i)", textBefore: "Hi Anna,\n") }
    try await waitFor(4, out)
    let calls = cleaner.calls.withLock { $0 }.sorted { $0.sequence < $1.sequence }
    #expect(calls[0].context == .init(previousLines: [], textBeforeCursor: "Hi Anna,\n"))
    #expect(calls[3].context?.previousLines.count == 2, "Only the previous two lines, never more")
    #expect(calls[3].context?.previousLines.allSatisfy { $0.hasPrefix("one ") || $0.hasPrefix("ONE ") } == true)

    await pipeline.reset()
    await pipeline.submit(sequence: 0, lineID: "n0", raw: "fresh start", textBefore: "")
    try await waitFor(5, out)
    let again = cleaner.calls.withLock { $0 }.last
    #expect(again?.context?.previousLines == [], "A new keyboard session starts with no context")
}

@Test func thePreviousLineIsCleanedTextOnceItsCallReturned() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(override: [0: "Hello there."])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    await pipeline.submit(sequence: 0, lineID: "a", raw: "hello there", textBefore: "")
    try await waitFor(1, out)
    await pipeline.submit(sequence: 1, lineID: "b", raw: "and so on", textBefore: "")
    try await waitFor(2, out)
    let second = cleaner.calls.withLock { $0 }.first { $0.sequence == 1 }
    #expect(second?.context?.previousLines == ["Hello there."])
}

// MARK: Request

private final class CapturingMessages: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let text: String
    init(text: String) { self.text = text }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        requests.withLock { $0.append(request) }
        let input = try! JSONDecoder().decode(JSONValue.self, from: request)
        let source = try! JSONDecoder().decode(JSONValue.self, from: Data(input["messages"]!.decode([JSONValue].self)[0]["content"]!.decode(String.self).utf8))
        let payload: JSONValue = .object(["sentenceID": source["sentenceID"]!, "sequence": source["sequence"]!, "text": .string(text)])
        func event(_ name: String, _ value: JSONValue) -> SSEEvent { .init(event: name, data: String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)) }
        return AsyncThrowingStream { continuation in
            continuation.yield(event("content_block_start", .object(["index": .number(0), "content_block": .object([
                "type": .string("tool_use"), "id": .string("t"), "name": .string("submit_sentence"), "input": payload])])))
            continuation.yield(event("content_block_stop", .object(["index": .number(0)])))
            continuation.yield(event("message_stop", .object(["type": .string("message_stop")])))
            continuation.finish()
        }
    }
}

@Test func dictationRequestUsesTheCacheableCleanupPromptAndAStableToolPrefix() async throws {
    let fixture = CapturingMessages(text: "\n")
    let client = SentenceCleanupClient(client: fixture)
    let a = try await client.clean(.init(sentenceID: "s-0", sequence: 0, text: "new line", vocabulary: ["Legato"],
        dictation: .init(previousLines: ["Hello."], textBeforeCursor: "Hi Anna,")))
    _ = try await client.clean(.init(sentenceID: "s-1", sequence: 1, text: "ok", vocabulary: [], dictation: .init()))
    #expect(a.text == "\n", "A spoken line break survives trimming")
    let requests = fixture.requests.withLock { $0 }.map { try! JSONDecoder().decode(JSONValue.self, from: $0) }
    let system = try #require(requests[0]["system"]).decode([JSONValue].self)
    #expect(system.count == 1 && system[0]["cache_control"]?["type"] == .string("ephemeral"))
    let promptValue = try #require(system[0]["text"])
    let prompt = try promptValue.decode(String.self)
    #expect(prompt.contains("Never rephrase") && prompt.contains("Never answer a question"))
    #expect(prompt.count > 2300, "About 600 tokens: above the 512-token minimum for prompt caching on Haiku 5.5")
    #expect(requests[0]["tools"] == requests[1]["tools"], "The tools come first in the cached prefix: they must not vary per line")
    #expect(requests[0]["system"] == requests[1]["system"])
    let user = try requests[0]["messages"]!.decode([JSONValue].self)[0]["content"]!.decode(String.self)
    #expect(user.contains("previousLines") && user.contains("textBeforeCursor") && user.contains("Hi Anna,"))
}

@Test func copyeditRequestsAreUnchangedByTheDictationMode() async throws {
    let fixture = CapturingMessages(text: "Hello.")
    _ = try await SentenceCleanupClient(client: fixture).clean(.init(sentenceID: "s", sequence: 0, text: "hello", vocabulary: []))
    let request = try JSONDecoder().decode(JSONValue.self, from: #require(fixture.requests.withLock { $0 }.first))
    let systemValue = try #require(request["system"])
    #expect(try systemValue.decode(String.self).contains("Copyedit one spoken sentence"))
    let toolsValue = try #require(request["tools"])
    let tool = try #require(try toolsValue.decode([JSONValue].self).first)
    #expect(tool["input_schema"]?["properties"]?["sentenceID"]?["enum"] == JSONValue.array([.string("s")]))
}
