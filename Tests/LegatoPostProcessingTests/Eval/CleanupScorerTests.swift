import Foundation
import Testing
@testable import LegatoPostProcessing

private func fixture(
    input: String = "hello world",
    mustContain: [String] = [],
    mustNotContain: [String] = [],
    reference: String = "Hello, world."
) -> CleanupFixture {
    CleanupFixture(
        name: "f", language: "en", length: "short", locale: "en-US", input: input, vocabulary: [],
        mustContain: mustContain, mustNotContain: mustNotContain, reference: reference)
}

@Suite("CleanupScorer")
struct CleanupScorerTests {
    // MARK: tokens and edit distance

    @Test func tokensDropPunctuationAndKeepOrder() {
        #expect(CleanupScorer.tokens("Hello, Wörld! It's 25€.", caseSensitive: true) == ["Hello", "Wörld", "It", "s", "25"])
    }

    @Test func tokensLowercaseWhenCaseDoesNotCount() {
        #expect(CleanupScorer.tokens("Hello, Wörld!", caseSensitive: false) == ["hello", "wörld"])
    }

    @Test(arguments: [
        (["a", "b", "c"], ["a", "b", "c"], 0),
        (["a", "b", "c"], ["a", "x", "c"], 1),
        (["a", "b", "c"], ["a", "c"], 1),
        (["a", "c"], ["a", "b", "c"], 1),
        ([], ["a", "b"], 2),
        (["a", "b"], [], 2),
        (["a", "b", "c", "d"], ["d", "c", "b", "a"], 4),
    ] as [([String], [String], Int)])
    func editDistanceCountsSubstitutionsInsertionsAndDeletions(_ row: ([String], [String], Int)) {
        #expect(CleanupScorer.editDistance(row.0, row.1) == row.2)
    }

    // MARK: must contain, must not contain

    @Test func everyRequiredTermPresentIsFullRecall() {
        let score = CleanupScorer.score(
            output: "Hello, world.", input: "hello world",
            fixture: fixture(mustContain: ["Hello", "world"]), rejectedChunks: 0)
        #expect(score.mustContainHits == 2)
        #expect(score.mustContainTotal == 2)
    }

    @Test func aMissingRequiredTermLowersTheHitsAndFailsTheFixture() {
        let score = CleanupScorer.score(
            output: "Hello, there.", input: "hello world",
            fixture: fixture(mustContain: ["Hello", "world"]), rejectedChunks: 0)
        #expect(score.mustContainHits == 1)
        #expect(!score.passed)
    }

    @Test func requiredTermsMatchCaseSensitively() {
        let score = CleanupScorer.score(
            output: "ask claude now", input: "ask kloud now",
            fixture: fixture(input: "ask kloud now", mustContain: ["Claude"], reference: "Ask Claude now."), rejectedChunks: 0)
        #expect(score.mustContainHits == 0)
    }

    @Test func forbiddenTermsAreListedAndFailTheFixture() {
        let score = CleanupScorer.score(
            output: "Hello, world. hello world", input: "hello world",
            fixture: fixture(mustContain: ["Hello"], mustNotContain: ["hello world", "Klaus"]), rejectedChunks: 0)
        #expect(score.violations == ["hello world"])
        #expect(!score.passed)
    }

    @Test func aFixtureWithNoRequirementsPassesWhenTheGuardAccepts() {
        let score = CleanupScorer.score(output: "Hello, world.", input: "hello world", fixture: fixture(), rejectedChunks: 0)
        #expect(score.passed)
    }

    // MARK: guard

    @Test func aRejectedChunkFailsTheFixtureEvenWhenTheKeptTextHasEveryTerm() {
        let score = CleanupScorer.score(
            output: "Hello, world.", input: "hello world",
            fixture: fixture(mustContain: ["Hello"]), rejectedChunks: 1)
        #expect(!score.guardAccepted)
        #expect(!score.passed)
    }

    @Test func anOutputThatDriftsFromTheInputIsNotAcceptedByTheGuard() {
        let score = CleanupScorer.score(
            output: "Hello, world. Thank you so much for your kind attention today.", input: "hello world",
            fixture: fixture(mustContain: ["Hello"]), rejectedChunks: 0)
        #expect(!score.guardAccepted)
        #expect(!score.passed)
    }

    @Test func aFaithfulOutputIsAcceptedByTheGuard() {
        let score = CleanupScorer.score(output: "Hello, world.", input: "hello world", fixture: fixture(), rejectedChunks: 0)
        #expect(score.guardAccepted)
    }

    // MARK: edit distance to the reference

    @Test func theReferenceItselfIsAtDistanceZero() {
        let score = CleanupScorer.score(output: "Hello, world.", input: "hello world", fixture: fixture(), rejectedChunks: 0)
        #expect(score.editDistance == 0)
        #expect(score.casedEditDistance == 0)
        #expect(score.referenceTokens == 2)
    }

    @Test func casingAndPunctuationDoNotCountInTheNormalizedDistanceButCasingCountsInTheCasedOne() {
        let score = CleanupScorer.score(output: "hello world", input: "hello world", fixture: fixture(), rejectedChunks: 0)
        #expect(score.editDistance == 0)
        #expect(score.casedEditDistance == 1)
    }

    @Test func aWrongWordCountsInBothDistances() {
        let score = CleanupScorer.score(
            output: "Hello, wild.", input: "hello world", fixture: fixture(), rejectedChunks: 0)
        #expect(score.editDistance == 1)
        #expect(score.casedEditDistance == 1)
    }

    // MARK: summary

    private func result(passed: Bool, hits: Int, total: Int, violations: [String], guardAccepted: Bool,
                        distance: Int, cased: Int, reference: Int, latency: Double) -> CleanupCaseResult {
        CleanupCaseResult(
            name: "n", output: "o", replies: [], latencySeconds: latency,
            score: CleanupScore(
                mustContainHits: hits, mustContainTotal: total, violations: violations, guardAccepted: guardAccepted,
                editDistance: distance, casedEditDistance: cased, referenceTokens: reference, passed: passed))
    }

    @Test func theSummaryAggregatesRatesCountsAndLatency() {
        let summary = CleanupSummary(results: [
            result(passed: true, hits: 3, total: 3, violations: [], guardAccepted: true, distance: 0, cased: 0, reference: 10, latency: 1),
            result(passed: false, hits: 1, total: 3, violations: ["a", "b"], guardAccepted: false, distance: 5, cased: 7, reference: 10, latency: 3),
        ])
        #expect(summary.fixtures == 2)
        #expect(summary.passed == 1)
        #expect(summary.passRate == 0.5)
        #expect(summary.mustContainRecall == 4.0 / 6.0)
        #expect(summary.violations == 2)
        #expect(summary.guardRejections == 1)
        #expect(summary.meanLatencySeconds == 2)
        #expect(summary.wer == 0.25)
        #expect(summary.casedWer == 0.35)
    }

    @Test func anEmptySummaryHasNoRatesToDivide() {
        let summary = CleanupSummary(results: [])
        #expect(summary.fixtures == 0)
        #expect(summary.passRate == 0)
        #expect(summary.mustContainRecall == 0)
        #expect(summary.meanLatencySeconds == 0)
    }

    // MARK: report

    @Test func theMarkdownTableHasOneRowPerVariantAndModel() {
        let run = CleanupEvalRun(
            variant: "V1", model: "qwen3-1.7b", split: "dev",
            results: [result(passed: true, hits: 3, total: 3, violations: [], guardAccepted: true, distance: 1, cased: 2, reference: 10, latency: 1.5)])
        let markdown = CleanupEvalReport.markdown(runs: [run])
        #expect(markdown.contains("| variant | model | split |"))
        #expect(markdown.contains("| V1 | qwen3-1.7b | dev | 1/1 (100%) | 100% | 0 | 0 | 1.50 | 10.0% | 20.0% |"))
    }

    @Test func aRunSurvivesAJSONRoundTrip() throws {
        let run = CleanupEvalRun(
            variant: "V0", model: "m", split: "heldout",
            results: [result(passed: true, hits: 1, total: 1, violations: [], guardAccepted: true, distance: 0, cased: 0, reference: 3, latency: 0.5)])
        let data = try CleanupEvalReport.json(runs: [run])
        let back = try JSONDecoder().decode([CleanupEvalRun].self, from: data)
        #expect(back == [run])
    }
}
