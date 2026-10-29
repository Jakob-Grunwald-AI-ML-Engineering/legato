import Foundation
import LegatoCore
import Testing
@testable import LegatoMLX

@Suite struct ProbeChunkerTests {
    private let sentences = ProbeChunker.sentences(corpus: ProbeCorpus.sentences, wordsPerSecond: 2.5, targetSeconds: 150)

    @Test func roundsReachTheTargetDuration() {
        let words = sentences.reduce(0) { $0 + ProbeChunker.words($1.text).count }
        #expect(Double(words) / 2.5 >= 150)
        #expect(sentences.count.isMultiple(of: ProbeCorpus.sentences.count))
        #expect(sentences.first?.id == "P01.r1")
    }

    @Test func chunksAreFiveToFifteenWordsAndCoverTheStreamInOrder() {
        let chunks = ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 95)
        for chunk in chunks.dropLast() { #expect((5...15).contains(chunk.words.count)) }
        #expect((1...15).contains(chunks.last!.words.count))
        let joined = chunks.flatMap(\.words).map(\.text)
        #expect(joined == sentences.flatMap { ProbeChunker.words($0.text) })
        #expect(chunks.map(\.index) == Array(chunks.indices))
    }

    @Test func pacingFollowsWordsPerSecond() {
        let chunks = ProbeChunker.chunks(sentences: sentences, wordsPerSecond: 2.5, seed: 95)
        var spoken = 0
        for chunk in chunks {
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
}

@Suite struct ProbeDocumentTests {
    private let corpus = [
        ProbeSentence(id: "A", text: "send teh report.", expectation: .removes(["teh"])),
        ProbeSentence(id: "B", text: "All good here today.", expectation: .noEdit),
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

    @Test func editsApplyToArrivedSentencesOnly() {
        var document = ProbeDocument(sentences: corpus)
        _ = document.receive(ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 2.5, seed: 1, minWords: 3, maxWords: 3)[0])
        let first = document.apply(SentenceEdit(sentence: 1, text: "Send the report."))
        let notArrived = document.apply(SentenceEdit(sentence: 2, text: "Nope."))
        let unknown = document.apply(SentenceEdit(sentence: 9, text: "Nope."))
        #expect(first && !notArrived && !unknown)
        #expect(document.entry(1)?.text == "Send the report.")
        #expect(document.request(touched: [1]).contains("1. Send the report."))
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
    @Test func medianAndNearestRankPercentile() {
        #expect(ProbeStats.median([]) == nil)
        #expect(ProbeStats.median([3, 1, 2]) == 2)
        #expect(ProbeStats.median([4, 1, 3, 2]) == 2.5)
        let values = (1...20).map(Double.init)
        #expect(ProbeStats.percentile(values, 95) == 19)
        #expect(ProbeStats.percentile(values, 100) == 20)
        #expect(ProbeStats.percentile([7], 95) == 7)
        #expect(ProbeStats.percent([true, false, true, true]) == 75)
        #expect(ProbeStats.percent([]) == 0)
    }

    private func record(_ chunk: Int, total: Int, speech: Int, prefill: Int? = nil, decode: (Int, Int)? = nil,
                        edits: Int = 0, applied: Int = 0, parseOK: Bool = true, error: String? = nil) -> ProbeTurnRecord {
        ProbeTurnRecord(chunk: chunk, words: 5, speechMs: speech, lagMs: chunk * 10, prefillMs: prefill, ttftMs: prefill,
                        ttftSource: "prefill", decodeTokens: decode?.0, decodeMs: decode?.1, totalMs: total,
                        keptUp: total < speech, reply: "", parseOK: parseOK, edits: edits, editsApplied: applied,
                        error: error, trimmed: chunk == 2)
    }

    @Test func summaryAggregatesTurnsAndExpectations() {
        let corpus = [
            ProbeSentence(id: "A", text: "send teh report.", expectation: .removes(["teh"])),
            ProbeSentence(id: "B", text: "All good here.", expectation: .noEdit),
            ProbeSentence(id: "C", text: "hello world.", expectation: .becomes("Hello world.")),
            ProbeSentence(id: "D", text: "Hmm.", expectation: .unchecked),
        ]
        var document = ProbeDocument(sentences: corpus)
        for chunk in ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 2.5, seed: 1) { _ = document.receive(chunk) }
        document.apply(SentenceEdit(sentence: 1, text: "Send the report."))
        document.apply(SentenceEdit(sentence: 2, text: "All is good here."))  // a false positive
        let records = [
            record(0, total: 1_000, speech: 2_000, prefill: 200, decode: (8, 400), edits: 1, applied: 1),
            record(1, total: 3_000, speech: 2_000, prefill: 300, decode: (10, 2_000), edits: 1, applied: 1),
            record(2, total: 2_000, speech: 4_000, parseOK: false),
            record(3, total: 50, speech: 2_000, parseOK: false, error: "boom"),
        ]
        let summary = ProbeSummary(records: records, document: document)
        #expect(summary.chunks == 4)
        #expect(summary.turnsFailed == 1)
        #expect(summary.medianMs == 2_000)
        #expect(summary.p95Ms == 3_000)
        #expect(summary.medianPrefillMs == 250)
        #expect(summary.medianDecodeTokensPerSecond == 12.5)  // median of 20 and 5 tok/s
        #expect(summary.keepUpPercent == 75)
        #expect(summary.maxLagMs == 30)
        #expect(summary.parseOKPercent == 50)
        #expect(summary.editsProduced == 2)
        #expect(summary.editsApplied == 2)
        #expect(summary.trims == 1)
        #expect(summary.expectationsChecked == 3)
        #expect(summary.expectationsMet == 1)
        #expect(summary.falsePositives == 1)
        #expect(summary.failedChecks == ["B", "C"])
    }

    @Test func theCorpusHasEveryFixtureAndTheTranscript() {
        let ids = Set(ProbeCorpus.sentences.map(\.id))
        for n in 1...12 { #expect(ids.contains(String(format: "P%02d", n))) }
        for n in 1...10 { #expect(ids.contains("T\(n)")) }
        // Every corpus entry is one sentence, so stream sentences coincide with corpus entries.
        for sentence in ProbeCorpus.sentences {
            #expect(sentence.text.last.map { ".!?".contains($0) } == true)
        }
    }

    @Test func configReadsTheEnvironment() {
        let config = ProbeConfig(environment: ["LEGATO_PROBE_WPS": "3", "LEGATO_PROBE_SECONDS": "60", "LEGATO_PROBE_SEED": "4"])
        #expect(config.wordsPerSecond == 3)
        #expect(config.targetSeconds == 60)
        #expect(config.seed == 4)
        #expect(config.window == 1_000)
    }
}
