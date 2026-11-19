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

@Test func unitsAreCleanedConcurrentlyUpToTheLimitAndDeliveredInOrder() async throws {
    let out = Collected()
    // Earlier units are slower: a later unit must neither wait for a slot nor overtake in delivery.
    let cleaner = ScriptedCleaner(delays: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, Duration.milliseconds(120 - 10 * $0)) }))
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    for i in 0..<8 { await pipeline.submit(sequence: i, lineID: "l\(i)", raw: "w\(i)", textBefore: "") }
    try await waitFor(8, out)
    #expect(cleaner.peak.withLock { $0 } == 4, "The default is four requests at once")
    #expect(out.all.map(\.sequence) == Array(0..<8))
    #expect(out.all.dropFirst(4).allSatisfy { ($0.queueWaitMs ?? 0) > 0 }, "Units beyond the limit report their wait")
}

@Test func aSpeculativeResultIsReusedWhenTheSameTextIsSubmitted() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(delays: [5: .milliseconds(80)])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    await pipeline.speculate(lineID: "l", sequence: 5, raw: "ship it on friday", textBefore: "Hi.")
    // Still running when the unit is sent: it is awaited, not asked again.
    await pipeline.submit(sequence: 5, lineID: "l", raw: "ship it on friday", textBefore: "Hi.")
    try await waitFor(1, out)
    #expect(cleaner.calls.withLock { $0.count } == 1)
    #expect(out.all[0].text == "SHIP IT ON FRIDAY" && out.all[0].speculation == "inflight")
    // Landed before the send: instant.
    await pipeline.speculate(lineID: "l", sequence: 6, raw: "and the budget too", textBefore: "")
    try await Task.sleep(for: .milliseconds(40))
    await pipeline.submit(sequence: 6, lineID: "l", raw: "and the budget too", textBefore: "")
    try await waitFor(2, out)
    #expect(cleaner.calls.withLock { $0.count } == 2)
    #expect(out.all[1].speculation == "landed")
}

@Test func aSpeculativeResultIsDiscardedWhenTheTextGrewOrAnotherSpeculationStarted() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(delays: [0: .milliseconds(200)])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, timeout: .seconds(2)) { out.add($0) }
    await pipeline.speculate(lineID: "l", sequence: 0, raw: "ship it on friday", textBefore: "")
    await pipeline.speculate(lineID: "l", sequence: 0, raw: "ship it on friday after lunch", textBefore: "")
    #expect(await pipeline.speculativeText == "ship it on friday after lunch", "The newest speculation wins")
    await pipeline.submit(sequence: 0, lineID: "l", raw: "ship it on friday after lunch and more", textBefore: "")
    try await waitFor(1, out)
    #expect(out.all[0].text == "SHIP IT ON FRIDAY AFTER LUNCH AND MORE" && out.all[0].speculation == nil)
    #expect(await pipeline.speculativeText == nil)
    // The same text asked twice is one request.
    #expect(await pipeline.speculate(lineID: "l", sequence: 1, raw: "a b c d e", textBefore: ""))
    #expect(await !pipeline.speculate(lineID: "l", sequence: 1, raw: "a b c d e", textBefore: ""))
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
    #expect(DictationCleanupGuard.accepts(raw: "um uh so like yeah um i mean it works", cleaned: "It works."))
    #expect(DictationCleanupGuard.accepts(raw: "new line", cleaned: "\n"))
    #expect(DictationCleanupGuard.accepts(raw: "dear anna comma", cleaned: "Dear Anna,"))
    #expect(!DictationCleanupGuard.accepts(raw: "what is the capital of france", cleaned: "The capital of France is Paris, a city on the Seine known for many sights."))
    #expect(!DictationCleanupGuard.accepts(raw: "i will be late today", cleaned: ""))
    // A few words: the result must still be what was said.
    #expect(!DictationCleanupGuard.accepts(raw: "okay", cleaned: "placeholder"))
    #expect(!DictationCleanupGuard.accepts(raw: "see you soon", cleaned: "placeholder"))
    #expect(!DictationCleanupGuard.accepts(raw: "thank you", cleaned: "We are welcome!"))
    #expect(DictationCleanupGuard.accepts(raw: "okay", cleaned: "Okay."))
    #expect(DictationCleanupGuard.accepts(raw: "lego toe", cleaned: "Legato"))
    #expect(DictationCleanupGuard.accepts(raw: "jacob", cleaned: "Jakob"))
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
    #expect(system.count == 1 && system[0]["cache_control"] == SentenceCleanupClient.dictationCache, "1-hour cache on the dictation prompt")
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

@Test func anEmptyResultDropsOnlyAFillerOrVeryShortLine() {
    #expect(DictationCleanupGuard.accepts(raw: "Um.", cleaned: ""))
    #expect(DictationCleanupGuard.accepts(raw: "Yeah.", cleaned: "  "))
    #expect(DictationCleanupGuard.accepts(raw: "um, uh, so yeah, you know, like, äh", cleaned: ""), "All fillers, however many")
    #expect(DictationCleanupGuard.accepts(raw: "I think.", cleaned: ""), "At most three words")
    #expect(!DictationCleanupGuard.accepts(raw: "um so the plan is ready for review", cleaned: ""), "Meaning would be lost")
    #expect(!DictationCleanupGuard.accepts(raw: "i will be late today", cleaned: ""))
    #expect(DictationCleanupGuard.accepts(raw: "new line", cleaned: "\n"), "A line break is no drop")
    #expect(!DictationTakeGuard.accepts(raw: "Um.", cleaned: ""), "A whole take is never dropped")
}

@Test func anEmptyResultIsDeliveredOnlyWhereTheCallerCanDropTheLine() async throws {
    let out = Collected()
    let cleaner = ScriptedCleaner(override: [0: "", 1: "", 2: ""])
    let pipeline = DictationCleanupPipeline(cleaner: cleaner) { out.add($0) }
    await pipeline.submit(sequence: 0, lineID: "a", raw: "Um.", textBefore: "", allowsEmpty: true)
    await pipeline.submit(sequence: 1, lineID: "b", raw: "the plan is ready for review", textBefore: "", allowsEmpty: true)
    await pipeline.submit(sequence: 2, lineID: "c", raw: "Um.", textBefore: "")
    try await waitFor(3, out)
    let lines = out.all
    #expect(lines[0].status == .cleaned && lines[0].text == "")
    #expect(lines[1].status == .raw && lines[1].reason == "rejected" && lines[1].text == "the plan is ready for review")
    #expect(lines[2].status == .raw && lines[2].reason == "failed" && lines[2].detail == "invalidText", "Line by line keeps its old outcome")
}

@Test func anEmptyDictationResultIsAResultButAnEmptyCopyeditIsNot() async throws {
    let client = SentenceCleanupClient(client: CapturingMessages(text: " "))
    let line = try await client.clean(.init(sentenceID: "s-0", sequence: 0, text: "Um.", vocabulary: [], dictation: .init()))
    #expect(line.text == "")
    await #expect(throws: SentenceCleanupError.invalidText) {
        _ = try await client.clean(.init(sentenceID: "s-1", sequence: 1, text: "Um.", vocabulary: []))
    }
}

@Test func aGermanUmBeforeATimeIsAWordNotAFiller() {
    #expect(!DictationCleanupGuard.accepts(raw: "wir treffen uns am Bahnhof so um sechs Uhr", cleaned: "Wir treffen uns am Bahnhof so sechs Uhr."))
    #expect(DictationCleanupGuard.accepts(raw: "wir treffen uns am Bahnhof so um sechs Uhr", cleaned: "Wir treffen uns am Bahnhof so um sechs Uhr."))
    #expect(DictationCleanupGuard.accepts(raw: "um drei nein sorry um vier", cleaned: "Um vier."), "A self-correction may drop one")
    #expect(DictationCleanupGuard.accepts(raw: "um so I think we go", cleaned: "I think we go."), "The English filler still goes")
    #expect(!DictationCleanupGuard.accepts(raw: "um 10 Uhr", cleaned: ""), "Never dropped whole")
    #expect(!DictationTakeGuard.accepts(raw: Array(repeating: "wir kommen um 10 Uhr", count: 4).joined(separator: " "),
                                        cleaned: Array(repeating: "Wir kommen 10 Uhr.", count: 4).joined(separator: " ")))
}

@Test func aLineRequestSizesItsOutputLimitToTheUnitAndMetricsReadTheStream() {
    #expect(SentenceCleanupClient.lineMaxTokens(characters: 20) == 384)
    #expect(SentenceCleanupClient.lineMaxTokens(characters: 2000) == 1256)
    #expect(SentenceCleanupClient.lineMaxTokens(characters: 100_000) == 4096)
    #expect(!SentenceCleanupClient.hasBegunText("{\"sentenceID\":\"a\",\"sequence\":1,\"te"))
    #expect(!SentenceCleanupClient.hasBegunText("{\"sentenceID\":\"a\",\"sequence\":1,\"text\":\""))
    #expect(SentenceCleanupClient.hasBegunText("{\"sentenceID\":\"a\",\"sequence\":1,\"text\":\"Ship"))
    let m = SentenceCleanupClient.metrics(model: "m", usage: ["input_tokens": .number(12), "cache_read_input_tokens": .number(900)],
                                          firstEventMs: 700, firstTextMs: 900, totalMs: 1100)
    #expect(m.inputTokens == 12 && m.cacheReadTokens == 900 && m.cacheCreationTokens == nil && m.outputTokens == nil)
}

// MARK: Send style (#316)

@Test func aSendUsesItsOwnCachedPromptAndAToolThatStaysTheSameBetweenSends() async throws {
    let fixture = CapturingMessages(text: "Dear Anna,\n\nthanks.\n\nBest regards,\nJakob")
    let client = SentenceCleanupClient(client: fixture)
    let said = "dear anna thanks and best regards jakob"
    _ = try await client.clean(.init(sentenceID: "s-0", sequence: 0, text: said, vocabulary: ["Jakob"], dictation: .init(style: .send)))
    _ = try await client.clean(.init(sentenceID: "s-1", sequence: 1, text: "ok", vocabulary: [], dictation: .init(textBeforeCursor: "Hi", style: .send)))
    _ = try await client.clean(.init(sentenceID: "s-2", sequence: 2, text: "ok", vocabulary: [], dictation: .init()))
    let requests = fixture.requests.withLock { $0 }.map { try! JSONDecoder().decode(JSONValue.self, from: $0) }
    let sendSystem = try #require(requests[0]["system"]).decode([JSONValue].self)
    let prompt = try #require(sendSystem[0]["text"]).decode(String.self)
    #expect(sendSystem[0]["cache_control"] == SentenceCleanupClient.dictationCache)
    #expect(prompt == PromptLayers.dictationSend() && prompt.contains("Never answer a question") && prompt.contains("Never translate"))
    #expect(requests[0]["system"] == requests[1]["system"] && requests[0]["tools"] == requests[1]["tools"], "The cached prefix is the same for every send")
    #expect(requests[0]["system"] != requests[2]["system"] && requests[0]["tools"] != requests[2]["tools"], "A line keeps its own prompt and tool")
    #expect(try requests[2]["system"]!.decode([JSONValue].self)[0]["text"]?.decode(String.self) == PromptLayers.dictationCleanup())
    #expect(requests[0]["max_tokens"] == .number(Double(SentenceCleanupClient.lineMaxTokens(characters: said.count, style: .send))))
    #expect(requests[0]["thinking"] == ModelChoice.haiku.thinking)
    let user = try requests[0]["messages"]!.decode([JSONValue].self)[0]["content"]!.decode(String.self)
    #expect(!user.contains("style"), "The style selects the prompt; it is not part of the request's data")
    #expect(SentenceCleanupClient.lineMaxTokens(characters: 20, style: .send) == 394)
    #expect(SentenceCleanupClient.lineMaxTokens(characters: 2000, style: .send) == 1384)
}

@Test func aPipelineCleansAndWarmsWithItsStyle() async throws {
    final class Warming: SentenceCleaning {
        let styles = Mutex<[DictationCleanupStyle?]>([])
        func clean(_ input: SentenceCleanupInput) async throws -> ValidatedSentence {
            styles.withLock { $0.append(input.dictation?.style) }
            return .init(sentenceID: input.sentenceID, sequence: input.sequence, text: input.text)
        }
        func warmDictation(_ style: DictationCleanupStyle) async { styles.withLock { $0.append(style) } }
    }
    let out = Collected()
    let cleaner = Warming()
    let pipeline = DictationCleanupPipeline(cleaner: cleaner, style: .send) { out.add($0) }
    await pipeline.warm()
    await pipeline.speculate(lineID: "a", sequence: 0, raw: "ship it on friday", textBefore: "")
    await pipeline.submit(sequence: 0, lineID: "a", raw: "ship it on friday", textBefore: "")
    await pipeline.submit(sequence: 1, lineID: "b", raw: "and the budget", textBefore: "")
    try await waitFor(2, out)
    #expect(cleaner.styles.withLock { $0 } == [.send, .send, .send])
    let line = DictationCleanupPipeline(cleaner: cleaner) { out.add($0) }
    await line.warm()
    #expect(cleaner.styles.withLock { $0 }.last == .line, "The default stays the line cleanup")
}

@Test func theSendGuardAcceptsShapedAndRephrasedTextAndStillRejectsAnswersStandInsAndSummaries() {
    let email = "Dear ladies and gentlemen, I am inquiring about a business proposal that you have sent me last week. And I would like to propose a meeting on, I don't know, next available time. Please send me 2 or 3 options, and best regards, Jacob Grunwald."
    let shaped = "Dear ladies and gentlemen,\n\nI am inquiring about a business proposal that you sent me last week. I would like to propose a meeting at the next available time. Please send me 2 or 3 options.\n\nBest regards,\nJakob Grunwald"
    #expect(DictationCleanupGuard.accepts(raw: email, cleaned: shaped, style: .send))
    #expect(DictationCleanupGuard.accepts(raw: "einkaufsliste erstens milch zweitens eier drittens brot und viertens äh butter",
                                          cleaned: "Einkaufsliste:\n1. Milch\n2. Eier\n3. Brot\n4. Butter", style: .send))
    #expect(DictationCleanupGuard.accepts(raw: "the budget is fifty thousand euros scratch that the budget is forty five thousand euros",
                                          cleaned: "The budget is forty-five thousand euros.", style: .send), "A spoken edit removes words")
    #expect(DictationCleanupGuard.accepts(raw: "ich schicke dir die unterlagen heute abend streich das ich schicke sie dir morgen früh",
                                          cleaned: "Ich schicke dir die Unterlagen morgen früh.", style: .send))
    #expect(DictationCleanupGuard.accepts(raw: "and best regards jakob", cleaned: "\n\nBest regards,\nJakob", style: .send))
    #expect(DictationCleanupGuard.accepts(raw: "um yeah", cleaned: "", style: .send))
    // Still rejected: an answer, a task carried out, a stand-in, a summary, a dropped preposition, an empty meaningful unit.
    #expect(!DictationCleanupGuard.accepts(raw: "what's the capital of australia again", cleaned: "The capital of Australia is Canberra, not Sydney as many people think.", style: .send))
    #expect(!DictationCleanupGuard.accepts(raw: "write an email to anna and tell her I'm running twenty minutes late",
                                           cleaned: "Hi Anna,\n\nsorry, I'm running about twenty minutes late. See you soon!\n\nBest,\nJakob", style: .send))
    #expect(!DictationCleanupGuard.accepts(raw: email, cleaned: "[Email requesting meeting options]", style: .send))
    #expect(!DictationCleanupGuard.accepts(raw: email, cleaned: "Dear ladies and gentlemen,\n\nplease send me options.\n\nBest regards,\nJakob Grunwald", style: .send))
    #expect(!DictationCleanupGuard.accepts(raw: "wir treffen uns so um sechs Uhr am Bahnhof", cleaned: "Wir treffen uns gegen sechs Uhr am Bahnhof.", style: .send))
    #expect(!DictationCleanupGuard.accepts(raw: "the plan is ready for review", cleaned: "", style: .send))
}

/// The eval's outputs against the send guard (`scripts/dev/cleanup-eval`): run with LEGATO_CLEANUP_EVAL_RESULTS set to its results file.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LEGATO_CLEANUP_EVAL_RESULTS"] != nil))
func cleanupEvalOutputsPassTheGuard() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LEGATO_CLEANUP_EVAL_RESULTS"]!)
    let results = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    guard case .object(let samples) = results["samples"] else { Issue.record("No samples"); return }
    for (id, entry) in samples.sorted(by: { $0.key < $1.key }) {
        let raw = try #require(entry["sample"]?["text"]).decode(String.self)
        guard case .object(let outputs) = entry["outputs"] else { continue }
        for (config, output) in outputs.sorted(by: { $0.key < $1.key }) {
            guard case .string(let text) = output["text"] else { continue }
            let style: DictationCleanupStyle = config.hasPrefix("send") ? .send : .line
            let accepted = DictationCleanupGuard.accepts(raw: raw, cleaned: text, style: style)
            print("cleanup-eval guard \(accepted ? "accepts" : "REJECTS") \(config) \(id)")
        }
    }
}
