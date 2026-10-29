import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoMLX

@Suite struct ProbeEndpointerTests {
    private func times(_ count: Int, from start: Int = 0, pace: Double = 2.5) -> [Double] {
        (0..<count).map { Double(start + $0 + 1) / pace }
    }

    @Test func terminalPunctuationEndsASentenceAtTheChunksDelivery() {
        var endpointer = ProbeEndpointer()
        let ready = endpointer.receive(["send", "it.", "Then", "call"], times: times(4), deliveredSeconds: 1.6)
        #expect(ready.map(\.words) == [0..<2])
        #expect(ready.first?.reason == .punctuation)
        #expect(ready.first.map { abs($0.delaySeconds - 0.8) < 1e-9 } == true)  // "it." spoken at 0.8 s, delivered at 1.6 s
        #expect(endpointer.finish(at: 2)?.words == 2..<4)
        #expect(endpointer.finish(at: 3) == nil)
    }

    @Test func titlesAndQuotesAreReadCorrectly() {
        #expect(!ProbeEndpointer.endsSentence("Dr."))
        #expect(!ProbeEndpointer.endsSentence("e.g."))
        #expect(ProbeEndpointer.endsSentence("done.\""))
        #expect(ProbeEndpointer.endsSentence("really?)"))
        #expect(!ProbeEndpointer.endsSentence("example.com"))
        #expect(!ProbeEndpointer.endsSentence("#um,"))
    }

    @Test func aPauseOrTheLengthLimitEndsARunOn() {
        var endpointer = ProbeEndpointer(config: .init(pauseSeconds: 0.7, maxWords: 3))
        // A 1 s gap before "next": the pending words are ready when the silence reached 0.7 s.
        let paused = endpointer.receive(["so", "then", "next"], times: [0.4, 0.8, 1.8], deliveredSeconds: 1.8)
        #expect(paused.map(\.words) == [0..<2])
        #expect(paused.first?.reason == .pause)
        #expect(paused.first.map { abs($0.detectedSeconds - 1.5) < 1e-9 } == true)
        let long = endpointer.receive(["and", "more", "words"], times: [2.2, 2.6, 3.0], deliveredSeconds: 3.0)
        #expect(long.map(\.words) == [2..<5])
        #expect(long.first?.reason == .length)
        _ = endpointer.receive(["tail"], times: [3.4], deliveredSeconds: 3.4)
        #expect(endpointer.silence(until: 3.8) == nil)
        #expect(endpointer.silence(until: 4.2)?.words == 5..<7)  // "words" and "tail"
    }
}

@Suite struct ProbeWordDiffTests {
    private func words(_ text: String) -> [String] { ProbeChunker.words(text) }

    @Test func changesBecomeMinimalHunks() {
        #expect(ProbeWordDiff.hunks(words("send teh report"), words("send teh report")).isEmpty)
        #expect(ProbeWordDiff.hunks(words("send teh report"), words("send the report")) == [.init(removed: 1..<2, inserted: ["the"])])
        #expect(ProbeWordDiff.hunks(words("#um, I like it"), words("I like it")) == [.init(removed: 0..<1, inserted: [])])
        #expect(ProbeWordDiff.hunks(words("I like beach"), words("I like the beach.")) == [
            .init(removed: 2..<3, inserted: ["the", "beach."]),
        ])
        #expect(ProbeWordDiff.hunks(words("a b c d"), words("a x c y")) == [
            .init(removed: 1..<2, inserted: ["x"]), .init(removed: 3..<4, inserted: ["y"]),
        ])
        #expect(ProbeWordDiff.hunks(words("a b"), words("a b c")) == [.init(removed: 2..<2, inserted: ["c"])])
    }
}

@Suite struct ProbeRewriteDocumentTests {
    private let corpus = [
        ProbeSentence(id: "A", passage: "p", tags: [], text: "send teh report", reference: "Send the report.",
                      mistakes: [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling")]),
        ProbeSentence(id: "B", passage: "p", tags: [], text: "on monday.", reference: "On Monday.",
                      mistakes: [ProbeMistake(wrong: "monday", fixes: ["Monday"], kind: .local, type: "casing")]),
    ]

    private func document() -> ProbeRewriteDocument {
        var document = ProbeRewriteDocument(sentences: corpus)
        let chunks = ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 10, seed: 1, minWords: 5, maxWords: 5)
        for chunk in chunks { document.receive(chunk) }
        return document
    }

    @Test func patchesLandInTheSentencesTheyTouch() {
        var document = document()
        // One endpointed segment spans both corpus sentences (sentence A had no full stop).
        let merged = ProbeRewriteMerge.merge("Send the report on Monday.", into: &document, range: 0..<5)
        #expect(merged.accepted)
        #expect(merged.changed.map(\.sentence) == [0, 1])
        #expect(document.sentenceText(0) == "Send the report")
        #expect(document.sentenceText(1) == "on Monday.")
        let effect = ProbeEditEffect.evaluate(before: merged.changed[0].before, after: merged.changed[0].after,
                                              mistakes: corpus[0].mistakes, fixedBefore: [false])
        #expect(effect.fixed == [0] && !effect.wrong)
        #expect(document.current(0..<5) == "Send the report on Monday.")
    }

    @Test func aDriftingReplyIsRejectedAndChangesNothing() {
        var document = document()
        let merged = ProbeRewriteMerge.merge("Here is a summary of your dictated note about a meeting.", into: &document, range: 0..<5)
        #expect(!merged.accepted)
        #expect(merged.changed.isEmpty)
        #expect(document.current(0..<5) == "send teh report on monday.")
    }

    @Test func anInsertionAtTheEndJoinsTheLastWord() {
        var document = document()
        let touched = document.apply([.init(removed: 3..<3, inserted: ["please"])], in: 0..<3)
        #expect(touched.map(\.sentence) == [0])
        #expect(document.sentenceText(0) == "send teh report please")
    }
}

@Suite struct ProbeRewriteReplyTests {
    @Test func labelsQuotesAndThinkBlocksAreRemoved() {
        #expect(ProbeRewriteReply.clean("<think>\n\n</think>\n\nSend the report.") == "Send the report.")
        #expect(ProbeRewriteReply.clean("\"Send the report.\"") == "Send the report.")
        #expect(ProbeRewriteReply.clean("Assistant: Send it.\n") == "Send it.")
        #expect(ProbeRewriteReply.clean("  \n ") == nil)
    }

    @Test func historyIsDroppedOldestFirstToFitTheBudget() {
        #expect(ProbeContextBudget.dropCount(fixed: 50, history: [10, 10, 10], budget: 100) == 0)
        #expect(ProbeContextBudget.dropCount(fixed: 80, history: [10, 10, 10], budget: 100) == 1)
        #expect(ProbeContextBudget.dropCount(fixed: 120, history: [10, 10], budget: 100) == 2)
        #expect(ProbeContextBudget.replyReserve(sentenceTokens: 10) == 36)
    }

    @Test func theEnvironmentPicksTheModeLayoutAndShare() {
        let config = ProbeConfig(environment: ["LEGATO_PROBE_MODE": "rewrite", "LEGATO_PROBE_LAYOUT": "turns",
                                               "LEGATO_PROBE_CTX_PCT": "50", "LEGATO_PROBE_PAUSE_MS": "900", "LEGATO_PROBE_MAX_WORDS": "20"])
        #expect(config.mode == .rewrite && config.layout == .turns && config.contextPercent == 50)
        #expect(config.endpoint == .init(pauseSeconds: 0.9, maxWords: 20))
        #expect(config.modeFields["mode"] as? String == "rewrite")
        let defaults = ProbeConfig(environment: [:])
        #expect(defaults.mode == .edits && defaults.layout == .onepass && defaults.contextPercent == 25)
        #expect(defaults.modeFields.count == 1)
    }
}

/// A session that records requests and trims, with a usage that grows by each turn.
private final class RewriteSession: LLMSession, @unchecked Sendable {
    let tokenBudget = 4_000
    let requests = Mutex<[String]>([])
    let trims = Mutex<[Int]>([])
    private let replies: Mutex<[String]>
    private let history = Mutex(0)
    init(replies: [String]) { self.replies = Mutex(replies) }
    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 100, history: history.withLock { $0 }) }
    func append(_ chunk: LLMSessionChunk) async throws {}
    func respond(to request: String) async throws -> String {
        requests.withLock { $0.append(request) }
        history.withLock { $0 += 60 }
        return replies.withLock { $0.isEmpty ? request : $0.removeFirst() }
    }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        throw LLMError.emptyResponse
    }
    func trim(keepingSuffix tokens: Int) async throws {
        trims.withLock { $0.append(tokens) }
        history.withLock { $0 = min($0, tokens) }
    }
    func warm() async throws {}
    func close() async {}
}

private final class RewriteBackend: LLMBackend, @unchecked Sendable {
    let sessions: Mutex<[RewriteSession]>
    init(_ sessions: [RewriteSession]) { self.sessions = Mutex(sessions) }
    var id: String { "rewrite" }
    var availability: LLMAvailability { get async { .available } }
    var maxPromptCharacters: Int? { nil }
    func respond(instructions: String, prompt: String) async throws -> String { "" }
    func makeSession() async throws -> any LLMSession { sessions.withLock { $0.removeFirst() } }
}

@Suite struct ContinuousRewriteRunTests {
    private let corpus = [
        ProbeSentence(id: "A", passage: "p", tags: ["lang:en"], text: "send teh report now.", reference: "Send the report now.",
                      mistakes: [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling")]),
        ProbeSentence(id: "B", passage: "q", tags: ["lang:en"], text: "All good here today and tomorrow.", reference: "All good here today and tomorrow.",
                      mistakes: []),
    ]

    private func config(_ layout: ProbeLayout, percent: Int = 25, window: Int = 1_000) -> ProbeConfig {
        var config = ProbeConfig(wordsPerSecond: 1_000, repeats: 1, warmContinuation: false, seed: 1)
        config.minWords = 5; config.maxWords = 5
        config.mode = .rewrite; config.layout = layout; config.contextPercent = percent; config.contextWindow = window
        return config
    }

    @Test func onePassSendsEachEndedSentenceWithTheEditedTextSoFar() async {
        let session = RewriteSession(replies: ["Send the report now.", "All good here today and tomorrow."])
        let records = Mutex<[ProbeTurnRecord]>([])
        let hooks = ContinuousAgentProbe.Hooks(countTokens: { _ in nil }, onTurn: { r in records.withLock { $0.append(r) } }, onEvent: { _, _ in })
        // Estimated counts (no tokenizer): the head alone is about 300 tokens, so the window is 4,000 (budget 1,000).
        let results = await ContinuousAgentProbe.runAll(backend: RewriteBackend([session]), config: config(.onepass, window: 4_000), hooks: hooks, corpus: corpus)
        let requests = session.requests.withLock { $0 }
        #expect(requests.count == 2)  // one per sentence, not per chunk
        #expect(requests[0] == "send teh report now.")
        #expect(requests[1] == "Text so far:\nSend the report now.\n\nSentence:\nAll good here today and tomorrow.")
        #expect(session.trims.withLock { $0 } == [0, 0])
        let run = results[0]
        #expect(run.mistakes[0].fixedChunk == run.mistakes[0].appearChunk)
        #expect(run.edits.map(\.wrong) == [false])
        let lines = records.withLock { $0 }
        #expect(lines.map(\.endpoint) == ["punctuation", "punctuation"])
        for line in lines {
            #expect(line.ctxBudget == 1_000)
            #expect(line.ctxWindow == 4_000)
            #expect(line.historyDropped == 0)
            #expect(line.rejected == false)
        }
        #expect(ProbeReport.pooled(results)["rejects"] as? String == "0/2")
    }

    @Test func turnsTrimTheOldestPairsBeforeTheBudgetIsReached() async {
        let session = RewriteSession(replies: [])  // echoes: no change
        let hooks = ContinuousAgentProbe.Hooks(countTokens: { _ in 10 }, onTurn: { _ in }, onEvent: { _, _ in })
        // 25 % of 1,000 = 250 holds head 100 + one 60-token turn + sentence 10 + reply reserve 36 (206).
        _ = await ContinuousAgentProbe.runAll(backend: RewriteBackend([session]), config: config(.turns, percent: 25), hooks: hooks, corpus: corpus)
        #expect(session.requests.withLock { $0 } == ["send teh report now.", "All good here today and tomorrow."])
        #expect(session.trims.withLock { $0 }.isEmpty)
        let tight = RewriteSession(replies: [])
        _ = await ContinuousAgentProbe.runAll(backend: RewriteBackend([tight]), config: config(.turns, percent: 15), hooks: hooks, corpus: corpus)
        // 15 % = 150 does not: the second request first trims the history to 150 - 100 - 10 - 36 = 4 tokens.
        let trims: [Int] = tight.trims.withLock { $0 }
        #expect(trims == [4])
    }
}
