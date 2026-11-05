import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoRoom
@testable import LegatoAgent

private final class TakeFixtureMessages: MessagesStreaming {
    let requests = Mutex<[Data]>([])
    let events: [SSEEvent]
    init(_ events: [SSEEvent]) { self.events = events }
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        requests.withLock { $0.append(request) }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
private func takeEvent(_ name: String, _ value: JSONValue) throws -> SSEEvent {
    .init(event: name, data: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
}
private func takeEvents(_ payload: JSONValue, tool: String = "submit_text") throws -> [SSEEvent] {
    [try takeEvent("content_block_start", .object(["index": .number(0), "content_block": .object([
        "type": .string("tool_use"), "id": .string("take-tool"), "name": .string(tool), "input": payload])])),
     try takeEvent("content_block_stop", .object(["index": .number(0)])),
     try takeEvent("message_stop", .object(["type": .string("message_stop")]))]
}

/// Scripted whole-take cleaner: pops one behaviour per call (the last repeats).
private final class ScriptedTakeCleaner: SentenceCleaning {
    enum Behavior: Sendable { case text(String), fail, hang, noKey }
    let script: Mutex<[Behavior]>
    let calls = Mutex(0)
    init(_ script: [Behavior]) { self.script = Mutex(script) }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence { throw SentenceCleanupError.invalidInput }
    func cleanTake(_ input: DictationTakeInput) async throws -> String {
        calls.withLock { $0 += 1 }
        let next = script.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        switch next {
        case .text(let text): return text
        case .fail: throw SentenceCleanupError.providerError
        case .hang: try await Task.sleep(for: .seconds(30)); return ""
        case .noKey: throw MessagesStreamError.missingKey
        }
    }
}

private let longRaw = "so I wanted to say that the meeting went well and we agreed on the plan for next week and then we talked about the budget"
private let longClean = "So I wanted to say that the meeting went well, and we agreed on the plan for next week. Then we talked about the budget."

@Test func takeTimeoutIsFourSecondsPlusOnePer200CharactersCappedAtTwenty() {
    #expect(DictationTakeLimits.timeout(characters: 0) == .seconds(4))
    #expect(DictationTakeLimits.timeout(characters: 199) == .seconds(4))
    #expect(DictationTakeLimits.timeout(characters: 200) == .seconds(5))
    #expect(DictationTakeLimits.timeout(characters: 1000) == .seconds(9))
    #expect(DictationTakeLimits.timeout(characters: 100_000) == .seconds(20))
}

@Test func takeTokenBudgetScalesWithTheInputWithinBounds() {
    #expect(DictationTakeLimits.maxTokens(characters: 10) == 1024)
    #expect(DictationTakeLimits.maxTokens(characters: 4000) == 2512)
    #expect(DictationTakeLimits.maxTokens(characters: 1_000_000) == 16_000)
}

@Test func takeGuardAcceptsAPunctuatedLongTextAndRejectsRewritesAnswersAndTruncation() {
    #expect(DictationTakeGuard.accepts(raw: longRaw, cleaned: longClean))
    // Fillers and a duplicated join word may drop.
    #expect(DictationTakeGuard.accepts(raw: "um " + longRaw + " the the", cleaned: longClean))
    // A paragraph break at a topic shift is fine.
    #expect(DictationTakeGuard.accepts(raw: longRaw, cleaned: longClean.replacingOccurrences(of: ". Then", with: ".\n\nThen")))
    #expect(!DictationTakeGuard.accepts(raw: longRaw, cleaned: ""))
    #expect(!DictationTakeGuard.accepts(raw: longRaw, cleaned: "The meeting went well."), "Summaries drop most words")
    #expect(!DictationTakeGuard.accepts(raw: longRaw, cleaned: longClean + " Please let me know if you would like me to draft a follow up email to the whole team about all of this."))
    #expect(!DictationTakeGuard.accepts(raw: longRaw, cleaned: "I cannot help with that request because it is not something that I am able to do for anyone at all today"))
    // Short takes use the per-line limits.
    #expect(DictationTakeGuard.accepts(raw: "hello there", cleaned: "Hello there."))
}

@Test func theTakeCleanerRetriesOnceAndThenGivesUp() async {
    let input = DictationTakeInput(takeID: "t", text: longRaw)
    let recovers = ScriptedTakeCleaner([.fail, .text(longClean)])
    #expect(await DictationTakeCleaner(cleaner: recovers).clean(input) == .cleaned(longClean))
    #expect(recovers.calls.withLock { $0 } == 2, "One automatic retry")

    let fails = ScriptedTakeCleaner([.fail])
    #expect(await DictationTakeCleaner(cleaner: fails).clean(input) == .failed(reason: "failed"))
    #expect(fails.calls.withLock { $0 } == 2)

    let rejected = ScriptedTakeCleaner([.text("Nope.")])
    #expect(await DictationTakeCleaner(cleaner: rejected).clean(input) == .failed(reason: "rejected"))
    #expect(rejected.calls.withLock { $0 } == 2)

    let hangs = ScriptedTakeCleaner([.hang])
    #expect(await DictationTakeCleaner(cleaner: hangs, timeout: { _ in .milliseconds(20) }).clean(input) == .failed(reason: "timeout"))
    #expect(hangs.calls.withLock { $0 } == 2)

    let keyless = ScriptedTakeCleaner([.noKey])
    #expect(await DictationTakeCleaner(cleaner: keyless).clean(input) == .unavailable)
    #expect(keyless.calls.withLock { $0 } == 1, "No key: nothing to retry")
}

@Test func theClientSubmitsTheWholeTakeThroughSubmitTextWithScaledTokens() async throws {
    let fixture = TakeFixtureMessages(try takeEvents(.object(["sentenceID": .string("take-1"), "text": .string(longClean)])))
    let client = SentenceCleanupClient(client: fixture)
    let text = try await client.cleanTake(.init(takeID: "take-1", text: longRaw, vocabulary: ["Legato"],
                                                recentTakes: [.init(raw: "earlier one", cleaned: "Earlier.", wasCleaned: true, date: .distantPast)], textBeforeCursor: "Hi Anna, "))
    #expect(text == longClean)
    let request = try JSONDecoder().decode(JSONValue.self, from: #require(fixture.requests.withLock { $0 }.first))
    #expect(request["model"] == .string(ModelChoice.haiku.rawValue))
    #expect(request["max_tokens"] == .number(Double(DictationTakeLimits.maxTokens(characters: longRaw.count))))
    #expect(request["tool_choice"]?["name"] == .string("submit_text"))
    let system = try #require(request["system"]).decode([JSONValue].self)
    #expect(system.first?["text"] == .string(PromptLayers.dictationTakeCleanup()))
    let messages = try #require(request["messages"]).decode([JSONValue].self)
    let content = try #require(messages.first?["content"]).decode(String.self)
    #expect(content.contains("recentTakes") && content.contains("earlier one") && content.contains("Earlier.") && content.contains("Hi Anna, ") && content.contains("take-1"))
    let keys = ["\"recentTakes\"", "\"sentenceID\"", "\"text\":\"\(longRaw.prefix(8))", "\"textBeforeCursor\"", "\"vocabulary\""].map { content.range(of: $0)?.lowerBound }
    #expect(keys.allSatisfy { $0 != nil } && keys == keys.sorted { $0! < $1! }, "The fields keep one order, whatever the run")
}

@Test(arguments: ["identity", "extra-field", "empty", "control", "wrong-tool", "oversized"])
func theClientRejectsMalformedTakeSubmissions(_ failure: String) async throws {
    var payload: JSONValue = .object(["sentenceID": .string("take-1"), "text": .string(longClean)])
    var tool = "submit_text"
    switch failure {
    case "identity": payload = .object(["sentenceID": .string("other"), "text": .string(longClean)])
    case "extra-field": payload = .object(["sentenceID": .string("take-1"), "text": .string(longClean), "note": .string("x")])
    case "empty": payload = .object(["sentenceID": .string("take-1"), "text": .string("  ")])
    case "control": payload = .object(["sentenceID": .string("take-1"), "text": .string("bad\u{0007}text")])
    case "wrong-tool": tool = "submit_sentence"
    default: payload = .object(["sentenceID": .string("take-1"), "text": .string(String(repeating: "a", count: 70_000))])
    }
    let client = SentenceCleanupClient(client: TakeFixtureMessages(try takeEvents(payload, tool: tool)))
    await #expect(throws: (any Error).self) { try await client.cleanTake(.init(takeID: "take-1", text: longRaw)) }
}

@Test func theClientRefusesAnEmptyOrOversizedTakeBeforeAnyRequest() async {
    let fixture = TakeFixtureMessages([])
    let client = SentenceCleanupClient(client: fixture)
    await #expect(throws: SentenceCleanupError.invalidInput) { try await client.cleanTake(.init(takeID: "t", text: "   ")) }
    await #expect(throws: SentenceCleanupError.invalidInput) { try await client.cleanTake(.init(takeID: "t", text: String(repeating: "word ", count: 8000))) }
    #expect(fixture.requests.withLock { $0 }.isEmpty)
}

// MARK: Streaming

private func deltaEvents(_ fragments: [String]) throws -> [SSEEvent] {
    var events = [try takeEvent("content_block_start", .object(["index": .number(0), "content_block": .object([
        "type": .string("tool_use"), "id": .string("take-tool"), "name": .string("submit_text"), "input": .object([:])])]))]
    for fragment in fragments {
        events.append(try takeEvent("content_block_delta", .object(["index": .number(0), "delta": .object([
            "type": .string("input_json_delta"), "partial_json": .string(fragment)])])))
    }
    events.append(try takeEvent("content_block_stop", .object(["index": .number(0)])))
    events.append(try takeEvent("message_stop", .object(["type": .string("message_stop")])))
    return events
}
private func collect(_ client: SentenceCleanupClient, _ id: String = "take-1") async throws -> [String] {
    var deltas: [String] = []
    for try await delta in client.cleanTakeStream(.init(takeID: id, text: longRaw)) { deltas.append(delta) }
    return deltas
}

@Test func theClientStreamsTheTextAsItArrivesAndTheDeltasAddUpToTheResult() async throws {
    let json = #"{"sentenceID":"take-1","text":"  So I wanted to say, \"hello\"\n\nThen we left. ä  "}"#
    for size in [1, 5, 1000] {
        let fragments = stride(from: 0, to: json.count, by: size).map { String(json.dropFirst($0).prefix(size)) }
        let client = SentenceCleanupClient(client: TakeFixtureMessages(try deltaEvents(fragments)))
        let deltas = try await collect(client)
        #expect(deltas.joined() == "So I wanted to say, \"hello\"\n\nThen we left. ä", "size \(size)")
        #expect(deltas.allSatisfy { !$0.isEmpty })
        if size == 1 { #expect(deltas.count > 10, "Text arrives piece by piece, not at the end") }
    }
}

@Test func aCompleteInputWithoutDeltasStillYieldsTheTextOnce() async throws {
    let client = SentenceCleanupClient(client: TakeFixtureMessages(try takeEvents(.object(["sentenceID": .string("take-1"), "text": .string(longClean)]))))
    #expect(try await collect(client) == [longClean])
}

@Test func aStreamFailsAfterItsDeltasWhenTheResultIsInvalid() async throws {
    let client = SentenceCleanupClient(client: TakeFixtureMessages(try deltaEvents([#"{"sentenceID":"other","te"#, #"xt":"Some words"}"#])))
    var deltas: [String] = []
    await #expect(throws: SentenceCleanupError.invalidIdentity) {
        for try await delta in client.cleanTakeStream(.init(takeID: "take-1", text: longRaw)) { deltas.append(delta) }
    }
    #expect(deltas.joined() == "Some words", "Validation runs at the end; the deltas already went out")
}

@Test func theDefaultStreamYieldsTheWholeResultOnceAndThrowsItsError() async throws {
    let ok = ScriptedTakeCleaner([.text("All at once.")])
    var got: [String] = []
    for try await delta in ok.cleanTakeStream(.init(takeID: "t", text: longRaw)) { got.append(delta) }
    #expect(got == ["All at once."])
    let broken = ScriptedTakeCleaner([.fail])
    await #expect(throws: SentenceCleanupError.providerError) {
        for try await _ in broken.cleanTakeStream(.init(takeID: "t", text: longRaw)) {}
    }
}

/// A cleaner that streams scripted pieces, then fails or ends.
private final class PiecewiseCleaner: SentenceCleaning {
    struct Attempt: Sendable { var pieces: [String]; var fails: Bool }
    let attempts: Mutex<[Attempt]>
    let calls = Mutex(0)
    init(_ attempts: [Attempt]) { self.attempts = Mutex(attempts) }
    func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence { throw SentenceCleanupError.invalidInput }
    func cleanTake(_ input: DictationTakeInput) async throws -> String { "" }
    func cleanTakeStream(_ input: DictationTakeInput) -> AsyncThrowingStream<String, any Error> {
        calls.withLock { $0 += 1 }
        let next = attempts.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        return AsyncThrowingStream { continuation in
            for piece in next.pieces { continuation.yield(piece) }
            if next.fails { continuation.finish(throwing: SentenceCleanupError.providerError) } else { continuation.finish() }
        }
    }
}
private final class Collected: @unchecked Sendable {
    private let lock = NSLock(); private var pieces: [String] = []
    func add(_ piece: String) { lock.withLock { pieces.append(piece) } }
    var all: [String] { lock.withLock { pieces } }
}

@Test func theStreamingCleanerRetriesOnlyBeforeAnyDeltaArrived() async {
    let input = DictationTakeInput(takeID: "t", text: longRaw)
    let early = PiecewiseCleaner([.init(pieces: [], fails: true), .init(pieces: ["Fine ", "now."], fails: false)])
    let got = Collected()
    let result = await DictationTakeCleaner(cleaner: early).cleanStreaming(input) { got.add($0) }
    #expect(result.result == .cleaned("Fine now.") && got.all == ["Fine ", "now."] && early.calls.withLock { $0 } == 2)

    let late = PiecewiseCleaner([.init(pieces: ["Half "], fails: true), .init(pieces: ["Never."], fails: false)])
    let seen = Collected()
    let failed = await DictationTakeCleaner(cleaner: late).cleanStreaming(input) { seen.add($0) }
    #expect(failed.result == .failed(reason: "failed") && seen.all == ["Half "] && late.calls.withLock { $0 } == 1, "A failure after deltas is surfaced, not retried")
}

@Test func theStreamingGuardReportsARejectionToTheCaller() async {
    let input = DictationTakeInput(takeID: "t", text: longRaw)
    let garbage = PiecewiseCleaner([.init(pieces: ["I am sorry, but I cannot help with that request because it is not something I can do for you today."], fails: false)])
    let outcome = await DictationTakeCleaner(cleaner: garbage).cleanStreaming(input) { _ in }
    #expect(outcome.rejected)
    if case .cleaned = outcome.result {} else { Issue.record("A finished stream reports its text with the rejection") }
    let oneWord = PiecewiseCleaner([.init(pieces: ["placeholder"], fails: false)])
    #expect(await DictationTakeCleaner(cleaner: oneWord).cleanStreaming(input) { _ in }.rejected, "A long take must not collapse to one word")
    let good = PiecewiseCleaner([.init(pieces: [longClean], fails: false)])
    #expect(await DictationTakeCleaner(cleaner: good).cleanStreaming(input) { _ in }.rejected == false)
}
