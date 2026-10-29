import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoMLX

@Suite struct ProbeCorpusTests {
    @Test func isLargeAndVaried() {
        #expect(ProbeCorpus.mistakeCount >= 50)
        let kinds = Set(ProbeCorpus.sentences.flatMap(\.mistakes).map(\.kind))
        #expect(kinds == [.local, .sentence])
        let tags = Set(ProbeCorpus.sentences.flatMap(\.tags))
        for tag in ["lang:en", "lang:de", "lang:mixed", "register:chat", "register:email", "register:note", "register:technical",
                    "register:explanatory", "style:run-on", "style:hesitant", "style:self-correction", "content:urls", "content:list"] {
            #expect(tags.contains(tag), "missing \(tag)")
        }
        let ids = Set(ProbeCorpus.sentences.map(\.id))
        for n in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12] { #expect(ids.contains(String(format: "P%02d", n))) }
        for n in 1...10 { #expect(ids.contains("T\(n)")) }
        #expect(ids.count == ProbeCorpus.sentences.count)
    }

    /// Every annotation is consistent: the wrong span is in the raw text, the raw text does not already count
    /// as fixed, and the clean reference fixes every mistake.
    @Test func annotationsMatchTheTextAndTheReference() {
        for sentence in ProbeCorpus.sentences {
            for mistake in sentence.mistakes {
                #expect(ProbeText.contains(sentence.text, mistake.wrong), "\(sentence.id): '\(mistake.wrong)' not in the text")
                #expect(!mistake.isFixed(in: sentence.text), "\(sentence.id): '\(mistake.wrong)' counts as fixed unedited")
                #expect(mistake.isFixed(in: sentence.reference), "\(sentence.id): the reference does not fix '\(mistake.wrong)'")
            }
        }
    }
}

@Suite struct ProbeTextTests {
    @Test func matchesOnWordBoundariesCaseSensitively() {
        #expect(ProbeText.contains("send teh report", "teh"))
        #expect(!ProbeText.contains("send tehran report", "teh"))
        #expect(!ProbeText.contains("hello world.", "wor"))
        #expect(ProbeText.contains("hello wor.", "wor"))
        #expect(!ProbeText.contains("It's windy", "Its"))
        #expect(!ProbeText.contains("Hello world", "hello"))
        #expect(ProbeText.contains("#um, I like", "#um"))
        #expect(!ProbeText.contains("#um, I like", "um"))
    }

    @Test func endWordIndexIsTheWordHoldingTheSpansEnd() {
        #expect(ProbeText.endWordIndex(of: "teh", in: "send teh report.") == 1)
        #expect(ProbeText.endWordIndex(of: "Te Beach", in: "#um, I like to go to Te Beach.") == 7)
        #expect(ProbeText.endWordIndex(of: "nope", in: "send teh report.") == nil)
    }

    @Test func editsAreScoredAgainstTheMistakes() {
        let mistakes = [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling"),
                        ProbeMistake(wrong: "monday", fixes: ["Monday"], kind: .local, type: "casing")]
        let before = "send teh report on monday."
        let one = ProbeEditEffect.evaluate(before: before, after: "Send the report on monday.", mistakes: mistakes, fixedBefore: [false, false])
        #expect(one.fixed == [0] && !one.wrong && !one.noop)
        let wrong = ProbeEditEffect.evaluate(before: before, after: "send teh memo on monday.", mistakes: mistakes, fixedBefore: [false, false])
        #expect(wrong.fixed.isEmpty && wrong.wrong)
        let noop = ProbeEditEffect.evaluate(before: before, after: "send  teh report on monday.", mistakes: mistakes, fixedBefore: [false, false])
        #expect(noop.noop && !noop.wrong)
        let undo = ProbeEditEffect.evaluate(before: "Send the report on monday.", after: "send teh report on Monday.", mistakes: mistakes,
                                            fixedBefore: [true, false])
        #expect(undo.fixed == [1] && undo.regressed == [0] && !undo.wrong)
        // Removal-only fixes.
        let filler = [ProbeMistake(wrong: "#um", fixes: [], kind: .local, type: "artefact")]
        #expect(ProbeEditEffect.evaluate(before: "#um, hi.", after: "Hi.", mistakes: filler, fixedBefore: [false]).fixed == [0])
    }
}

@Suite struct ProbeChunkerTests {
    private let sentences = ProbeCorpus.sentences

    @Test func chunksAreFiveToFifteenWordsAndCoverTheStreamInOrder() {
        let chunks = ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 95)
        for chunk in chunks.dropLast() { #expect((5...15).contains(chunk.words.count)) }
        #expect((1...15).contains(chunks.last!.words.count))
        #expect(chunks.flatMap(\.words).map(\.text) == sentences.flatMap { ProbeChunker.words($0.text) })
        #expect(chunks.map(\.index) == Array(chunks.indices))
    }

    @Test func pacingFollowsWordsPerSecond() {
        var spoken = 0
        for chunk in ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 95) {
            #expect(chunk.firstWord == spoken)
            spoken += chunk.words.count
            #expect(abs(chunk.dueSeconds - Double(spoken) / 2.5) < 1e-9)
            #expect(abs(chunk.speechSeconds - Double(chunk.words.count) / 2.5) < 1e-9)
        }
    }

    @Test func theSeedFixesTheChunks() {
        let a = ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 7)
        #expect(a == ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 7))
        #expect(a.map(\.words.count) != ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 8).map(\.words.count))
    }

    @Test func localMistakesAppearWithTheirSpanAndRewritesWithTheSentenceEnd() {
        let corpus = [
            ProbeSentence(id: "A", passage: "p", tags: [], text: "one two teh four five six seven eight.", reference: "",
                          mistakes: [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling"),
                                     ProbeMistake(wrong: "one two", fixes: [], kind: .sentence, type: "rewrite")]),
        ]
        let chunks = ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 1, seed: 1, minWords: 3, maxWords: 3)
        #expect(ProbeChunker.appearance(sentences: corpus, chunks: chunks) == [[0, 2]])
    }

    @Test func everyCorpusMistakeHasAnAppearanceChunk() {
        let chunks = ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 95)
        #expect(ProbeChunker.appearance(sentences: sentences, chunks: chunks).flatMap { $0 }.allSatisfy { $0 != nil })
    }
}

@Suite struct ProbeDocumentTests {
    private let corpus = [
        ProbeSentence(id: "A", passage: "p", tags: [], text: "send teh report.", reference: "Send the report.",
                      mistakes: [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling")]),
        ProbeSentence(id: "B", passage: "p", tags: [], text: "All good here today.", reference: "All good here today.", mistakes: []),
    ]

    @Test func requestsListTouchedSentencesAndReviewOnlyFinishedOnes() {
        var document = ProbeDocument(sentences: corpus)
        let chunks = ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 2.5, seed: 1, minWords: 4, maxWords: 4)
        let touched = document.receive(chunks[0])  // "send teh report." + "All"
        #expect(touched == [1, 2])
        #expect(document.request(touched: touched) == """
            <sentences>
            1. send teh report.
            2. All
            </sentences>
            Review: 1.
            Reply [] or one edit {"sentence":n,"text":"…"}.
            """)
    }

    @Test func aContinuationNumbersPastThePreviousRun() {
        var document = ProbeDocument(sentences: corpus, numberOffset: 40)
        let chunks = ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 2.5, seed: 1, minWords: 3, maxWords: 3)
        #expect(document.receive(chunks[0]) == [41])
        #expect(document.index(of: 41) == 0)
        #expect(document.index(of: 1) == nil)
        #expect(document.index(of: 42) == nil)  // not started yet
    }
}

@Suite struct ProbeReplyTests {
    @Test func emptyArrayIsNoEdit() {
        #expect(ProbeReply.parse("[]") == .noEdit)
        #expect(ProbeReply.parse("  <think>\n\n</think>\n\n[]\n") == .noEdit)
        #expect(ProbeReply.parse("```json\n[]\n```") == .noEdit)
    }

    @Test func oneObjectIsAnExactEdit() {
        #expect(ProbeReply.parse(#"{"sentence": 3, "text": "Send the report."}"#)
            == .edits([SentenceEdit(sentence: 3, text: "Send the report.")], exact: true))
    }

    @Test func anArrayOfObjectsIsAcceptedButFlagged() {
        let reply = ProbeReply.parse(#"[{"sentence":1,"text":"A."},{"sentence":2,"text":"B."}]"#)
        #expect(reply == .edits([SentenceEdit(sentence: 1, text: "A."), SentenceEdit(sentence: 2, text: "B.")], exact: false))
        #expect(reply.parseOK)
    }

    @Test(arguments: [
        "Sure! Here is the fix.", "", #"{"sentence": "3", "text": "x"}"#, #"{"sentence": 3.5, "text": "x"}"#,
        #"{"sentence": true, "text": "x"}"#, #"{"sentence": 3, "text": "x", "why": "y"}"#, #"[{"sentence": 1}]"#,
        "<think>unfinished", "```json\n[]",
    ])
    func anythingElseIsInvalid(_ raw: String) {
        #expect(!ProbeReply.parse(raw).parseOK)
    }
}

@Suite struct ProbeStatsTests {
    @Test func orderStatisticsMeanAndSpread() {
        #expect(ProbeStats.median([]) == nil)
        #expect(ProbeStats.median([3, 1, 2]) == 2)
        #expect(ProbeStats.median([4, 1, 3, 2]) == 2.5)
        let values = (1...20).map(Double.init)
        #expect(ProbeStats.percentile(values, 95) == 19)
        #expect(ProbeStats.percentile(values, 100) == 20)
        #expect(ProbeStats.percentile([7], 95) == 7)
        #expect(ProbeStats.mean([2, 4, 6]) == 4)
        #expect(ProbeStats.standardDeviation([2, 4, 6]) == 2)
        #expect(ProbeStats.standardDeviation([5]) == nil)
        #expect(ProbeStats.percent([true, false, true, true]) == 75)
        #expect(ProbeStats.percent([]) == 0)
        let fields = ProbeStats.describe([100, 300, 200], "x")
        #expect(fields["xN"] as? Int == 3 && fields["xMean"] as? Int == 200 && fields["xMedian"] as? Int == 200
                && fields["xP95"] as? Int == 300 && fields["xSd"] as? Int == 100)
    }

    private func outcome(_ kind: ProbeMistakeKind, appear: Double, fixed: Double?, chunks: Int? = nil, tags: [String] = ["lang:en"]) -> ProbeMistakeOutcome {
        var o = ProbeMistakeOutcome(rep: 1, phase: "fresh", sentence: "S", passage: "p", tags: tags,
                                    mistake: ProbeMistake(wrong: "x", fixes: [], kind: kind, type: "spelling"),
                                    appearChunk: 0, appearSeconds: appear)
        if let fixed { o.fixedSeconds = fixed; o.fixedChunk = chunks ?? 0 }
        return o
    }

    @Test func qualityReportsLatencyPerKindFixRatesAndWrongEdits() {
        let mistakes = [
            outcome(.local, appear: 1, fixed: 1.5), outcome(.local, appear: 2, fixed: 3, chunks: 3), outcome(.local, appear: 3, fixed: nil),
            outcome(.sentence, appear: 4, fixed: 6),
        ]
        let edits = [ProbeEditOutcome(rep: 1, chunk: 0, passage: "p", tags: [], applied: true, wrong: false, noop: false),
                     ProbeEditOutcome(rep: 1, chunk: 1, passage: "p", tags: [], applied: true, wrong: true, noop: false)]
        let fields = ProbeQuality(mistakes: mistakes, edits: edits).fields
        #expect(fields["localFixed"] as? String == "2/3")
        #expect(fields["localFixedWithin2"] as? String == "1/3")
        #expect(fields["localLatencyMsMedian"] as? Int == 750)
        #expect(fields["localLatencyMsN"] as? Int == 2)
        #expect(fields["sentenceFixed"] as? String == "1/1")
        #expect(fields["sentenceLatencyMsMean"] as? Int == 2_000)
        #expect(fields["fixed"] as? String == "3/4")
        #expect(fields["wrongEdits"] as? String == "1/2")
        #expect(fields["wrongEditPct"] as? Double == 50)
    }

    @Test func configReadsTheEnvironment() {
        let config = ProbeConfig(environment: ["LEGATO_PROBE_WPS": "3", "LEGATO_PROBE_REPEATS": "2", "LEGATO_PROBE_WARM": "0",
                                               "LEGATO_PROBE_SEED": "4"], defaultRepeats: 3)
        #expect(config.wordsPerSecond == 3 && config.repeats == 2 && !config.warmContinuation && config.seed == 4 && config.window == 1_000)
        #expect(ProbeConfig(environment: [:], defaultRepeats: 1).repeats == 1)
        #expect(ProbeConfig(environment: [:]).warmContinuation)
    }
}

/// A scripted backend: replies in order, one session at a time.
private final class ScriptedSession: LLMSession, @unchecked Sendable {
    let tokenBudget = 4_000
    let requests = Mutex<[String]>([])
    private let replies: Mutex<[String]>
    init(replies: [String]) { self.replies = Mutex(replies) }
    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: 0) }
    func append(_ chunk: LLMSessionChunk) async throws {}
    func respond(to request: String) async throws -> String {
        requests.withLock { $0.append(request) }
        return replies.withLock { $0.isEmpty ? "[]" : $0.removeFirst() }
    }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        throw LLMError.emptyResponse
    }
    func trim(keepingSuffix tokens: Int) async throws {}
    func warm() async throws {}
    func close() async {}
}

private final class ScriptedBackend: LLMBackend, @unchecked Sendable {
    let sessions: Mutex<[ScriptedSession]>
    init(sessions: [ScriptedSession]) { self.sessions = Mutex(sessions) }
    var id: String { "scripted" }
    var availability: LLMAvailability { get async { .available } }
    var maxPromptCharacters: Int? { nil }
    func respond(instructions: String, prompt: String) async throws -> String { "" }
    func makeSession() async throws -> any LLMSession { sessions.withLock { $0.removeFirst() } }
}

@Suite struct ContinuousAgentProbeRunTests {
    private let corpus = [
        ProbeSentence(id: "A", passage: "p", tags: ["lang:en"], text: "send teh report now.", reference: "Send the report now.",
                      mistakes: [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling")]),
        ProbeSentence(id: "B", passage: "q", tags: ["lang:de"], text: "All good here today and tomorrow.", reference: "All good here today and tomorrow.",
                      mistakes: []),
    ]

    @Test func fixesWrongEditsAndTheWarmContinuationAreMeasured() async {
        // Chunks of 5 words: chunk 0 = sentence 1 + "All", chunk 1 = the rest of sentence 2.
        let first = ScriptedSession(replies: [#"{"sentence":1,"text":"Send the report now."}"#, #"{"sentence":2,"text":"All bad."}"#])
        // The second run fixes nothing; its session carries on into the warm continuation, numbered from 3.
        let second = ScriptedSession(replies: ["[]", "[]", "[]", #"{"sentence":3,"text":"Send the report now."}"#])
        let backend = ScriptedBackend(sessions: [first, second])
        let lines = Mutex<[String]>([])
        let hooks = ContinuousAgentProbe.Hooks(countTokens: { _ in nil }, onTurn: { _ in },
                                               onEvent: { name, _ in lines.withLock { $0.append(name) } })
        var config = ProbeConfig(wordsPerSecond: 1_000, repeats: 2, warmContinuation: true, seed: 1)
        config.minWords = 5; config.maxWords = 5
        let results = await ContinuousAgentProbe.runAll(backend: backend, config: config, hooks: hooks, corpus: corpus)
        #expect(results.map(\.phase) == ["fresh", "fresh", "warm"])
        #expect(results.map(\.rep) == [1, 2, 3])
        let run1 = results[0]
        #expect(run1.mistakes.count == 1 && run1.mistakes[0].fixedChunk == run1.mistakes[0].appearChunk)
        #expect((run1.mistakes[0].latencyMs ?? -1) >= 0)
        #expect(run1.edits.map(\.wrong) == [false, true])
        #expect(results[1].mistakes[0].fixedChunk == nil)
        #expect(results[2].mistakes[0].fixedChunk != nil)
        let pooled = ProbeReport.pooled(results)
        #expect(pooled["runs"] as? Int == 2)
        #expect(pooled["localFixed"] as? String == "1/2")
        #expect(pooled["wrongEdits"] as? String == "1/2")
        let breakdown = ProbeReport.breakdown(results)
        #expect(breakdown.contains { $0.group == "tag:lang:en" && $0.fields["localFixed"] as? String == "1/2" })
        #expect(breakdown.contains { $0.group == "type:spelling" })
        #expect(first.requests.withLock { $0.count } == 2)
        #expect(second.requests.withLock { $0.count } == 4)
        #expect(lines.withLock { $0 }.filter { $0 == "run" }.count == 3)
        #expect(lines.withLock { $0 }.filter { $0 == "mistake" }.count == 3)
    }
}
