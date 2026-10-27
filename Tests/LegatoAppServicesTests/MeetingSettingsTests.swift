import Foundation
import LegatoClaude
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

    @Test func theClaudeDisclosureIsForgottenWheneverTheKeyChangesOrGoes() throws {
        let s = settings()
        let keys = InMemoryAPIKeyStore()
        #expect(!s.claudeDisclosureAccepted)

        try s.storeClaudeKey("  sk-one \n", in: keys)
        #expect(try keys.apiKey() == "sk-one")
        s.claudeDisclosureAccepted = true

        try s.storeClaudeKey("sk-two", in: keys)  // a different key: the user is told again
        #expect(try keys.apiKey() == "sk-two")
        #expect(!s.claudeDisclosureAccepted)

        s.claudeDisclosureAccepted = true
        try s.storeClaudeKey("   ", in: keys)  // removed
        #expect(try keys.apiKey() == nil)
        #expect(!s.claudeDisclosureAccepted)
    }

    @Test func aKeychainFailureKeepsTheDisclosure() {
        struct Refused: Error {}
        struct Broken: APIKeyStore {
            func apiKey() throws -> String? { nil }
            func save(apiKey: String) throws { throw Refused() }
            func deleteKey() throws {}
        }
        let s = settings()
        s.claudeDisclosureAccepted = true
        #expect(throws: Refused.self) { try s.storeClaudeKey("sk-x", in: Broken()) }
        #expect(s.claudeDisclosureAccepted)
    }
}
