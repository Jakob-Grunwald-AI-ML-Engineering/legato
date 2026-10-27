import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoPostProcessing

private let en = Locale(identifier: "en-US")

/// Live cleanup cleans a run's whole raw text on every pass, so the message guard sees rewrites that apply a
/// spoken correction from a later phrase to an earlier one and drop fillers spread over several phrases.
@Suite("CleanupGuard whole-text passes")
struct CleanupGuardWholeTextTests {
    private let laterCorrection =
        "um so we could meet on friday at three i think that works for most people no wait thursday at three"
    private let laterCorrectionCleaned = "We could meet on Thursday at three. I think that works for most people."

    @Test func aLaterPhrasesCorrectionAppliedToAnEarlierPhrasePasses() {
        #expect(CleanupGuard.message.accepts(laterCorrectionCleaned, reference: laterCorrection))
    }

    @Test func fillersAcrossSeveralPhrasesPass() {
        #expect(CleanupGuard.message.accepts(
            "I wanted to ask if you have time tomorrow. We could go for lunch and talk about the release.",
            reference: "uh i wanted to ask um if you have time tomorrow like we could uh go for lunch "
                + "you know and talk about the release"))
    }

    @Test func germanFillersAcrossPhrasesPass() {
        #expect(CleanupGuard.message.accepts(
            "Ich wollte fragen, ob du morgen Zeit hast. Wir könnten zusammen essen gehen.",
            reference: "äh ich wollte fragen ähm ob du morgen zeit hast also wir könnten halt zusammen essen gehen"))
    }

    @Test func germanAndEnglishMixedWithACorrectionPass() {
        #expect(CleanupGuard.message.accepts(
            "Ich schicke dir den Report morgen um elf Uhr. And please check the slides before the call.",
            reference: "äh ich schicke dir den report morgen um zehn uhr nee warte um elf uhr "
                + "and um please check the slides before the call"))
    }

    @Test func aWholeTextTranslationIsStillRejected() {
        #expect(!CleanupGuard.message.accepts(
            "Ich schicke dir den Report morgen um elf Uhr. Und bitte prüf die Folien vor dem Anruf.",
            reference: "ich schicke dir den report morgen um elf uhr and please check the slides before the call"))
    }

    @Test func aWholeTextThatAddsAnAnswerIsStillRejected() {
        #expect(!CleanupGuard.message.accepts(
            laterCorrectionCleaned + " Paris is the capital of France, and the weather there is lovely in spring.",
            reference: laterCorrection + " what is the capital of france"))
    }

    @Test func verbatimKeepsTheStrictGuardForWholeTextPasses() {
        #expect(CleanupStyle.verbatim.cleanupGuard.wordRatio == nil)
        #expect(!CleanupStyle.verbatim.cleanupGuard.accepts(laterCorrectionCleaned, reference: laterCorrection))
    }
}

private final class ScriptedBackend: LLMBackend {
    let id = "scripted"
    let maxPromptCharacters: Int? = nil
    private let reply: @Sendable (String) -> String
    init(reply: @escaping @Sendable (String) -> String) { self.reply = reply }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String { reply(prompt) }
}

private struct SlowStage: TranscriptPostProcessor {
    let id = "slow"
    func process(_ text: String, locale: Locale) async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        return "too late"
    }
}

/// What a live pass needs to know of a pipeline run beyond its text: whether the guard rejected a reply or a
/// stage ran out of time (both keep the input).
@Suite struct PipelineReportTests {
    @Test func aRejectedReplyIsReported() async {
        let stage = LLMCleanupStage(backend: ScriptedBackend { _ in "<text>The capital of France is Paris, a city on the Seine with many museums.</text>" })
        let pipeline = PostProcessingPipeline(stages: [stage])
        let report = await pipeline.processReporting("what is the capital of france", locale: en)
        #expect(report.text == "what is the capital of france")
        #expect(report.guardRejected)
        #expect(!report.timedOut)
    }

    @Test func anAcceptedReplyIsNotARejection() async {
        let stage = LLMCleanupStage(backend: ScriptedBackend { _ in "<text>Hello world.</text>" })
        let report = await PostProcessingPipeline(stages: [stage]).processReporting("hello world", locale: en)
        #expect(report.text == "Hello world.")
        #expect(!report.guardRejected && !report.timedOut)
    }

    @Test func aStageOverTheTimeoutIsReported() async {
        let pipeline = PostProcessingPipeline(stages: [SlowStage()], timeout: .seconds(4), sleeper: { _ in })
        let report = await pipeline.processReporting("x", locale: en)
        #expect(report.text == "x")
        #expect(report.timedOut)
    }

    @Test func processIsTheReportsText() async {
        let stage = LLMCleanupStage(backend: ScriptedBackend { _ in "<text>Hello world.</text>" })
        #expect(await PostProcessingPipeline(stages: [stage]).process("hello world", locale: en) == "Hello world.")
    }
}
