import Foundation
import LegatoCore
import Testing
@testable import LegatoPostProcessing

@Suite struct PipelineFailureReportTests {
    private struct RefusingStage: TranscriptPostProcessor {
        let id = "refusing"
        func process(_ text: String, locale: Locale) async throws -> String { throw LLMError.unavailable(reason: "Not prepared") }
    }
    @Test func aFailedStageRetainsTextAndReportsFailureInsteadOfSuccess() async {
        let result = await PostProcessingPipeline(stages: [RefusingStage()]).processReporting("Tomorrow at nine", locale: Locale(identifier: "en"))
        #expect(result.text == "Tomorrow at nine")
        #expect(result.failed == true)
        #expect(result.timedOut == false)
    }
    @Test func successfulUnchangedTextIsNotReportedAsFailure() async {
        let result = await PostProcessingPipeline(stages: []).processReporting("Tomorrow at nine", locale: Locale(identifier: "en"))
        #expect(result.text == "Tomorrow at nine")
        #expect(result.failed == false)
    }
}
