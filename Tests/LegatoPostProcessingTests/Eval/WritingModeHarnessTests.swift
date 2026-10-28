import Foundation
import Testing

@Suite("Writing mode evaluation harness")
struct WritingModeHarnessTests {
    @Test func timeoutDefaultsRemainBackendSpecificAndOverrideMatchesUserSetting() throws {
        let foundation = try WritingModeDeadline(defaultSeconds: 4, configured: nil)
        let coreML = try WritingModeDeadline(defaultSeconds: 8, configured: nil)
        #expect(foundation.appliedSeconds == 4)
        #expect(coreML.appliedSeconds == 8)
        #expect(foundation.configuredSeconds == nil)
        #expect(foundation.source == "backend-default")
        let override = try WritingModeDeadline(defaultSeconds: 4, configured: "10")
        #expect(override.defaultSeconds == 4)
        #expect(override.configuredSeconds == 10)
        #expect(override.appliedSeconds == 10)
        #expect(override.source == "explicit-user-setting")
        #expect(try WritingModeDeadline(defaultSeconds: 8, configured: "1").appliedSeconds == 1)
    }

    @Test(arguments: ["", "bad", "0", "0.5", "10.1", "11", "-1", "nan", "inf", "-inf"])
    func timeoutRejectsInvalidOrOutOfRangeValues(_ value: String) {
        #expect(throws: WritingModeEvalError.self) {
            try WritingModeDeadline(defaultSeconds: 4, configured: value)
        }
    }

    @Test func fixtureSchemaRejectsMissingSemanticContract() throws {
        var fixture = try WritingModeFixtures.load(.dev)[0]
        fixture.meaning = []
        #expect(throws: WritingModeEvalError.self) { try fixture.validate() }
    }

    @Test func fixtureSplitsAreSeparateAndHaveBilingualAndMixedCoverage() throws {
        let dev = try WritingModeFixtures.load(.dev)
        let validation = try WritingModeFixtures.load(.validation)
        #expect(Set(dev.map(\.id)).isDisjoint(with: Set(validation.map(\.id))))
        #expect(Set(dev.map(\.input)).isDisjoint(with: Set(validation.map(\.input))))
        for fixtures in [dev, validation] {
            #expect(Set(fixtures.map(\.language)) == ["de", "en", "mixed"])
            #expect(Set(fixtures.map(\.mode)) == ["verbatim", "message", "markdown"])
            #expect(fixtures.contains { $0.input.count > 2400 })
            for fixture in fixtures { try fixture.validate() }
        }
    }

    @Test func paraphraseDoesNotRequireReferenceWordingOrWordOverlap() throws {
        let fixture = try WritingModeFixtures.load(.dev).first { $0.id == "dev-message-restructure" }!
        let output = "Could you send Mira the revised sketch? The old attachment is obsolete; I can review the replacement this evening."
        #expect(WritingModeChecks.failures(output, fixture: fixture).isEmpty)
        #expect(!WritingModeChecks.failures("The sketch was approved yesterday.", fixture: fixture).isEmpty)
    }

    @Test func markdownStructureAndInternalParagraphsAreChecked() throws {
        let fixture = try WritingModeFixtures.load(.dev).first { $0.id == "dev-markdown-list" }!
        #expect(WritingModeChecks.failures("# Lab\n\n- Calibrate the sensor\n- Save the log", fixture: fixture).isEmpty)
        #expect(WritingModeChecks.failures("Lab: calibrate the sensor and save the log.", fixture: fixture).contains("paragraphs"))
        #expect(WritingModeChecks.failures("Lab: calibrate the sensor and save the log.", fixture: fixture).contains("list"))
    }

    @Test func emojiCountsGraphemesAndDoesNotTreatDigitsAsEmoji() throws {
        #expect(WritingModeChecks.emojiCount("Meet at 14:20, room 7.") == 0)
        #expect(WritingModeChecks.emojiCount("Thanks 👩🏽‍💻 🇩🇪 ❤️") == 3)
        var fixture = try WritingModeFixtures.load(.dev)[0]
        fixture.required = []
        fixture.forbidden = []
        fixture.maxEmoji = 0
        #expect(WritingModeChecks.failures("Thanks 🙂", fixture: fixture).contains("emoji-maximum"))
        fixture.minEmoji = 1
        fixture.maxEmoji = 2
        #expect(WritingModeChecks.failures("Thanks", fixture: fixture).contains("emoji-minimum"))
    }

    @Test func allUnavailableCannotBecomeQualitySuccess() {
        let summary = WritingModeSummary(completed: 0, unavailable: 4, operationalFailures: 0, objectiveFailures: 0)
        #expect(!summary.objectiveSuccess)
        #expect(!summary.validatedQuality)
    }

    @Test func automaticPassStillRequiresIndependentReview() {
        let summary = WritingModeSummary(completed: 12, unavailable: 0, operationalFailures: 0, objectiveFailures: 0)
        #expect(summary.objectiveSuccess)
        #expect(!summary.validatedQuality)
    }

    @Test func summarySerializesExplicitObjectiveAndReviewStatus() throws {
        let data = try JSONEncoder().encode(WritingModeSummary(completed: 4))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["objectiveSuccess"] as? Bool == true)
        #expect(object["validatedQuality"] as? Bool == false)
        #expect(object["reviewStatus"] as? String == "pending independent semantic and naturalness review")
    }

    @Test func deadlineReportsTimeoutWithoutWaitingForUncooperativeWorker() async {
        let result = await writingModeBounded(seconds: 0.01) {
            // Unstructured delay deliberately ignores the caller's cancellation.
            await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
            return "late"
        }
        #expect(result.timedOut)
        if case .success = result.result { Issue.record("Timed-out response was reported as success") }
        await result.worker.value
    }

    @Test func deadlinePreservesBackendErrorIdentityForProductionFallback() async {
        let result: WritingModeBounded<String> = await writingModeBounded(seconds: 1) {
            throw WritingModeEvalError("fixture-boundary-error")
        }
        #expect(!result.timedOut)
        if case .failure(let error) = result.result {
            #expect((error as? WritingModeEvalError)?.description == "fixture-boundary-error")
        } else { Issue.record("Backend error was lost") }
    }

    @Test func operationalFallbackCannotCountAsObjectiveSuccess() {
        let summary = WritingModeSummary(completed: 1, unavailable: 0, operationalFailures: 1, objectiveFailures: 0)
        #expect(!summary.objectiveSuccess)
    }

    @Test func cancelledCallerCanObserveLateWorkerSettlement() async {
        let worker = Task.detached { _ = try? await Task.sleep(for: .milliseconds(150)) }
        let observer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let settled = await writingModeWaitForSettlement(worker: worker, seconds: 1)
            return (settled, Task.isCancelled)
        }
        let (settled, callerStillCancelled) = await observer.value
        #expect(settled == true)
        #expect(callerStillCancelled == true)
        await worker.value
    }

    @Test func cancelledCallerSettlementStillHonorsFiniteGrace() async {
        // Keep the worker pending until the assertion, independent of CI scheduling delays.
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let worker = Task.detached { for await _ in release {} }
        let observer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await writingModeWaitForSettlement(worker: worker, seconds: 0.01)
        }
        #expect(await observer.value == false)
        continuation.finish()
        await worker.value
    }
}
