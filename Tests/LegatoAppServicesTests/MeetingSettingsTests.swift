import Foundation
import LegatoClaude
import LegatoMeetings
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

@Suite struct MeetingSettingsTemplateTests {
    private let suite = "legato.meeting-settings.\(UUID().uuidString)"
    private func settings() -> MeetingSettings { MeetingSettings(defaults: UserDefaults(suiteName: suite)!) }

    @Test func withNothingSetTheTemplatesAreTheFiveBuiltInsAndSummaryIsTheDefault() {
        let s = settings()
        #expect(s.customTemplates.isEmpty)
        #expect(s.allTemplates.map(\.id) == ["summary", "action-items", "email-follow-up", "one-on-one", "brainstorm"])
        #expect(s.defaultTemplateID == "summary")
        #expect(s.template(id: "brainstorm")?.name == "Brainstorm")
        #expect(s.template(id: "nope") == nil)
    }

    @Test func customTemplatesAreAddedEditedAndDeleted() {
        let s = settings()
        let a = s.addTemplate(name: "Standup", prompt: "List blockers.")
        let b = s.addTemplate(name: "Standup", prompt: "Second.")
        #expect(a.id != b.id, "ids are unique even for equal names")
        #expect(s.customTemplates.map(\.name) == ["Standup", "Standup"])
        #expect(s.allTemplates.count == 7)

        var edited = a
        edited.name = "Daily"
        edited.prompt = "List blockers and wins."
        s.updateTemplate(edited)
        #expect(s.template(id: a.id) == edited)

        s.deleteTemplate(id: a.id)
        #expect(s.customTemplates.map(\.id) == [b.id])
        // Persisted.
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: suite)!).customTemplates.map(\.id) == [b.id])
    }

    @Test func builtInsCannotBeEditedOrDeleted() {
        let s = settings()
        var changed = SummaryTemplate.summary
        changed.prompt = "Hacked"
        s.updateTemplate(changed)
        s.deleteTemplate(id: "summary")
        #expect(s.template(id: "summary") == .summary)
        #expect(s.allTemplates.count == 5)
    }

    @Test func theDefaultTemplateIsRememberedAndFallsBackToSummaryWhenItsTemplateIsDeleted() {
        let s = settings()
        let mine = s.addTemplate(name: "Mine", prompt: "p")
        s.defaultTemplateID = mine.id
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: suite)!).defaultTemplateID == mine.id)
        s.deleteTemplate(id: mine.id)
        #expect(s.defaultTemplateID == "summary")
        s.defaultTemplateID = "no-such-template"
        #expect(s.defaultTemplateID == "summary", "an unknown id is not a default")
    }

    @Test func theOldPromptMigratesIntoMyTemplateAndBecomesTheDefault() {
        let s = settings()
        s.customPrompt = "Only list decisions."
        #expect(s.customTemplates.map(\.name) == ["My template"])
        #expect(s.customTemplates.first?.prompt == "Only list decisions.")
        #expect(s.customTemplates.first?.id == SummaryTemplate.migratedID)
        #expect(s.defaultTemplateID == SummaryTemplate.migratedID, "the user's prompt keeps being used")
        #expect(s.allTemplates.count == 6)
    }

    @Test func theMigrationRunsOnce() {
        let s = settings()
        s.customPrompt = "Only list decisions."
        _ = s.customTemplates
        var mine = try! #require(s.template(id: SummaryTemplate.migratedID))
        mine.prompt = "Edited since."
        s.updateTemplate(mine)
        s.defaultTemplateID = "summary"
        s.customPrompt = "A later change to the old setting."
        #expect(s.template(id: SummaryTemplate.migratedID)?.prompt == "Edited since.")
        #expect(s.defaultTemplateID == "summary")

        s.deleteTemplate(id: SummaryTemplate.migratedID)
        #expect(s.customTemplates.isEmpty, "a deleted My template does not come back")
    }

    @Test func anEmptyOrDefaultOldPromptMigratesNothing() {
        let empty = settings()
        #expect(empty.customTemplates.isEmpty)
        let same = MeetingSettings(defaults: UserDefaults(suiteName: "legato.meeting-settings.\(UUID().uuidString)")!)
        same.customPrompt = SummaryTemplate.summary.prompt
        #expect(same.customTemplates.isEmpty)
        #expect(same.defaultTemplateID == "summary")
    }
}

@Suite struct MeetingSettingsProcessingTests {
    private let suite = "legato.meeting-settings.\(UUID().uuidString)"
    private func settings() -> MeetingSettings { MeetingSettings(defaults: UserDefaults(suiteName: suite)!) }

    @Test func diarizationAndIdleProcessingAreOnByDefaultAndPersist() {
        let s = settings()
        #expect(s.liveDiarization && s.offlineDiarization && s.idleProcessing)
        s.liveDiarization = false
        s.offlineDiarization = false
        s.idleProcessing = false
        let again = settings()
        #expect(!again.liveDiarization && !again.offlineDiarization && !again.idleProcessing)
    }

    @Test func theLanguageIsAutoByDefaultAndRemembersTheLastUsed() {
        let s = settings()
        #expect(s.language == nil)
        s.language = "de-DE"
        #expect(settings().language == "de-DE")
        s.language = nil
        #expect(settings().language == nil)
    }

    @Test func echoAndNoiseDefaultsToLocalVQE() {
        #expect(settings().echoNoise == .localVQE)
    }

    @Test func theOldVoiceProcessingFalseMigratesToOffAndTrueOrUnsetToLocalVQE() {
        let off = UserDefaults(suiteName: "legato.meeting-settings.\(UUID().uuidString)")!
        off.set(false, forKey: "meeting.voiceProcessing")
        #expect(MeetingSettings(defaults: off).echoNoise == .off)

        let on = UserDefaults(suiteName: "legato.meeting-settings.\(UUID().uuidString)")!
        on.set(true, forKey: "meeting.voiceProcessing")
        #expect(MeetingSettings(defaults: on).echoNoise == .localVQE)
    }

    @Test func anExplicitChoiceBeatsTheOldValue() {
        let d = UserDefaults(suiteName: "legato.meeting-settings.\(UUID().uuidString)")!
        d.set(false, forKey: "meeting.voiceProcessing")
        let s = MeetingSettings(defaults: d)
        s.echoNoise = .appleVoiceProcessing
        #expect(MeetingSettings(defaults: d).echoNoise == .appleVoiceProcessing)
        s.echoNoise = .off
        #expect(MeetingSettings(defaults: d).echoNoise == .off)
    }

    @Test func theOldToggleStillMapsOntoTheChoice() {
        let s = settings()
        s.echoNoise = .appleVoiceProcessing
        s.voiceProcessing = true
        #expect(s.echoNoise == .appleVoiceProcessing, "on keeps the chosen method")
        s.voiceProcessing = false
        #expect(s.echoNoise == .off)
        s.voiceProcessing = true
        #expect(s.echoNoise == .localVQE, "turned on from off: the default method")
    }
}
