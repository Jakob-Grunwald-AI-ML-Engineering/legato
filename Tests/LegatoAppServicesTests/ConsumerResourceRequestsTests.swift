import Foundation
import LegatoCore
import LegatoCoreML
import LegatoModels
import Testing
@testable import LegatoAppServices

@MainActor struct ConsumerResourceRequestsTests {
    private func modelServices() -> (ModelServices, UserDefaults) {
        let defaults = UserDefaults(suiteName: "consumer-resources-\(UUID().uuidString)")!
        let models = ModelServices(root: .temporaryDirectory.appending(path: UUID().uuidString), defaults: defaults,
                                   platform: .macOS, installers: [:])
        SelectionStore(defaults: defaults).set(CoreMLModels.qwen3_1_7bID, for: .cleanup)
        return (models, defaults)
    }
    @Test func disabledCleanupRequiresOnlySpeechAndRetainsRefineAndIndependentMeetingChoice() async throws {
        let (models, defaults) = modelServices()
        let cleanup = CleanupSettingsStore(defaults: defaults)
        cleanup.enabled = false
        cleanup.backend = .coreML
        let meeting = MeetingSettings(defaults: defaults)
        meeting.backend = .foundationModels
        let requests = await models.selectedResourceRequests(options: cleanup.options)
        #expect(requests[.dictation]?.map(\.key) == ["speech:apple:auto"])
        #expect(requests[.refine]?.map(\.key) == ["cleanup:coreml-qwen3-1.7b-lut6"])
        #expect(requests[.meetingSummary]?.map(\.key) == ["cleanup:foundation-models"])
    }
    @Test func foundationDictationAndCoreMLMeetingRetainBothExplicitModels() async throws {
        let (models, defaults) = modelServices()
        let cleanup = CleanupSettingsStore(defaults: defaults)
        cleanup.enabled = true
        cleanup.backend = .foundationModels
        let meeting = MeetingSettings(defaults: defaults)
        meeting.backend = .coreML
        let requests = await models.selectedResourceRequests(options: cleanup.options)
        #expect(requests[.dictation]?.map(\.key) == ["speech:apple:auto", "cleanup:foundation-models"])
        #expect(requests[.meetingSummary]?.map(\.key) == ["cleanup:coreml-qwen3-1.7b-lut6"])
        let resource = try #require(requests[.meetingSummary]?.first)
        await #expect(throws: LLMError.self) { try await resource.lifecycle.prewarmResources() }
        #expect(await models.manager.state(of: CoreMLModels.qwen3_1_7bID) == .notInstalled)
    }
    @Test func missingMeetingWeightsNeverBecomeReadyAndBackgroundDoesNotLoadThem() async throws {
        let (models, _) = modelServices()
        await #expect(throws: SelectedModelWarmup.PreparationError.needsForeground) {
            try await models.acquireSummaryBackend(backend: .coreML, inBackground: true)
        }
        await #expect(throws: LLMError.self) { try await models.acquireSummaryBackend(backend: .coreML, inBackground: false) }
        #expect(await models.manager.state(of: CoreMLModels.qwen3_1_7bID) == .notInstalled)
    }
}
