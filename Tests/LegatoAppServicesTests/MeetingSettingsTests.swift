import Foundation
import Testing
@testable import LegatoAppServices

@Suite struct MeetingSettingsTests {
    private func settings() -> MeetingSettings {
        MeetingSettings(defaults: UserDefaults(suiteName: "legato.meeting-settings.\(UUID().uuidString)")!)
    }

    @Test func defaults() {
        let s = settings()
        #expect(s.customPrompt == "")
        #expect(s.backend == .auto)
        #expect(s.voiceProcessing)
        #expect(s.autoMute)
    }

    @Test func valuesPersist() {
        let suite = "legato.meeting-settings.\(UUID().uuidString)"
        let s = MeetingSettings(defaults: UserDefaults(suiteName: suite)!)
        s.customPrompt = "Only action items."
        s.backend = .foundationModels
        s.voiceProcessing = false
        s.autoMute = false
        let again = MeetingSettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(again.customPrompt == "Only action items.")
        #expect(again.backend == .foundationModels)
        #expect(!again.voiceProcessing)
        #expect(!again.autoMute)
    }
}
