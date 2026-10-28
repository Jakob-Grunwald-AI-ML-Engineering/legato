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
        #expect(s.backend == .foundationModels)
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

/// Jakob: "I would prefer to not have the templates as single-select. Multiple select of sections/items feels
/// better." Settings hold the sections (built in and custom), their order and the default ticks.
@Suite struct MeetingSettingsSectionTests {
    private let suite = "legato.meeting-settings.\(UUID().uuidString)"
    private func settings() -> MeetingSettings { MeetingSettings(defaults: UserDefaults(suiteName: suite)!) }
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private let builtInIDs = ["summary", "decisions", "action-items", "open-questions", "email-follow-up", "one-on-one", "brainstorm"]

    /// An older install's templates, as it stored them.
    private func storeOldTemplates(_ templates: [(id: String, name: String, prompt: String)]) throws {
        let json = templates.map { ["id": $0.id, "name": $0.name, "prompt": $0.prompt] }
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "meeting.templates")
    }

    @Test func withNothingSetTheSectionsAreTheBuiltInsAndTheDefaultTicksAreSummaryDecisionsAndActionItems() {
        let s = settings()
        #expect(s.customSections.isEmpty)
        #expect(s.allSections.map(\.id) == builtInIDs)
        #expect(s.defaultSectionIDs == ["summary", "decisions", "action-items"])
        #expect(s.section(id: "brainstorm")?.heading == "Brainstorm")
        #expect(s.section(id: "nope") == nil)
    }

    @Test func theAutomaticSummaryIsOffByDefaultAndPersists() {
        let s = settings()
        #expect(!s.summarizeAutomatically)
        s.summarizeAutomatically = true
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: suite)!).summarizeAutomatically)
    }

    @Test func customSectionsAreAddedEditedAndDeleted() {
        let s = settings()
        let a = s.addSection(heading: "Risks", instruction: "Bullets for each risk.")
        let b = s.addSection(heading: "Risks", instruction: "Second.")
        #expect(a.id != b.id, "ids are unique even for equal headings")
        #expect(s.customSections.map(\.heading) == ["Risks", "Risks"])
        #expect(s.allSections.map(\.id) == builtInIDs + [a.id, b.id], "a new section goes last")

        var edited = a
        edited.heading = "Blockers"
        edited.instruction = "Bullets for each blocker."
        s.updateSection(edited)
        #expect(s.section(id: a.id) == edited)

        s.deleteSection(id: a.id)
        #expect(s.customSections.map(\.id) == [b.id])
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: suite)!).customSections.map(\.id) == [b.id], "persisted")
    }

    @Test func builtInsCannotBeEditedOrDeleted() throws {
        let s = settings()
        var changed = try #require(s.section(id: "summary"))
        let original = changed
        changed.instruction = "Hacked"
        s.updateSection(changed)
        s.deleteSection(id: "summary")
        #expect(s.section(id: "summary") == original)
        #expect(s.allSections.count == 7)
    }

    @Test func sectionsAreReorderedAndTheOrderPersists() {
        let s = settings()
        let mine = s.addSection(heading: "Risks", instruction: "r")
        s.moveSections(fromOffsets: IndexSet(integer: 7), toOffset: 0)  // the custom one first
        #expect(s.allSections.first?.id == mine.id)
        s.moveSections(fromOffsets: IndexSet(integer: 2), toOffset: 1)  // decisions (now third) above summary
        #expect(Array(s.allSections.map(\.id).prefix(3)) == [mine.id, "decisions", "summary"])
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: suite)!).allSections.map(\.id) == s.allSections.map(\.id))
    }

    @Test func theDefaultTicksAreRememberedInTheConfiguredOrderAndForgetWhatIsGone() {
        let s = settings()
        let mine = s.addSection(heading: "Risks", instruction: "r")
        s.defaultSectionIDs = [mine.id, "brainstorm", "no-such-section"]
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: suite)!).defaultSectionIDs == ["brainstorm", mine.id])
        s.deleteSection(id: mine.id)
        #expect(s.defaultSectionIDs == ["brainstorm"])
        s.defaultSectionIDs = []
        #expect(s.defaultSectionIDs == [], "no default ticks is a choice")
    }

    @Test func aMeetingsSectionsAreItsTicksOrTheDefaultInTheConfiguredOrder() {
        let s = settings()
        s.defaultSectionIDs = ["decisions"]
        let plain = Meeting(title: "T", date: Date(), engineID: "e")
        #expect(s.sections(for: plain).map(\.id) == ["decisions"], "nil: the default ticks")
        let ticked = Meeting(title: "T", date: Date(), engineID: "e", sections: ["brainstorm", "gone", "summary"])
        #expect(s.sections(for: ticked).map(\.id) == ["summary", "brainstorm"])
    }

    @Test func togglingAChipTicksOrUnticksItInTheConfiguredOrder() {
        let s = settings()
        let plain = Meeting(title: "T", date: Date(), engineID: "e")  // the default ticks
        #expect(s.ticks(of: plain, toggling: "open-questions") == ["summary", "decisions", "action-items", "open-questions"])
        #expect(s.ticks(of: plain, toggling: "decisions") == ["summary", "action-items"])
        let mine = Meeting(title: "T", date: Date(), engineID: "e", sections: ["brainstorm", "gone"])
        #expect(s.ticks(of: mine, toggling: "summary") == ["summary", "brainstorm"], "what is gone drops out")
        #expect(s.ticks(of: mine, toggling: "brainstorm") == [])
    }

    // MARK: Migration from templates

    @Test func oldCustomTemplatesBecomeCustomSections() throws {
        try storeOldTemplates([("custom-1", "Standup", "List blockers."), ("custom-2", "Retro", "What went well.")])
        let s = settings()
        #expect(s.customSections.map(\.id) == ["custom-1", "custom-2"])
        #expect(s.customSections.map(\.heading) == ["Standup", "Retro"])
        #expect(s.customSections.map(\.instruction) == ["List blockers.", "What went well."])
        #expect(s.defaultSectionIDs == ["summary", "decisions", "action-items"])
    }

    @Test func theOldDefaultTemplateBecomesTheDefaultTicks() throws {
        try storeOldTemplates([("custom-1", "Standup", "List blockers.")])
        defaults.set("custom-1", forKey: "meeting.defaultTemplate")
        #expect(settings().defaultSectionIDs == ["custom-1"])

        let brainstorm = "legato.meeting-settings.\(UUID().uuidString)"
        UserDefaults(suiteName: brainstorm)!.set("brainstorm", forKey: "meeting.defaultTemplate")
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: brainstorm)!).defaultSectionIDs == ["brainstorm"])

        let summary = "legato.meeting-settings.\(UUID().uuidString)"
        UserDefaults(suiteName: summary)!.set("action-items", forKey: "meeting.defaultTemplate")
        #expect(MeetingSettings(defaults: UserDefaults(suiteName: summary)!).defaultSectionIDs == ["action-items"])
    }

    @Test func theOldPromptBecomesMyNotesAndTheDefaultTicks() {
        let s = settings()
        s.customPrompt = "Only list decisions."
        #expect(s.customSections.map(\.heading) == ["My notes"])
        #expect(s.customSections.first?.instruction == "Only list decisions.")
        #expect(s.customSections.first?.id == SummarySection.migratedID)
        #expect(s.defaultSectionIDs == [SummarySection.migratedID], "the user's prompt keeps being used")
    }

    @Test func anAlreadyMigratedMyTemplateBecomesMyNotes() throws {
        try storeOldTemplates([("my-template", "My template", "Only list decisions.")])
        defaults.set(true, forKey: "meeting.templatesMigrated")
        defaults.set("my-template", forKey: "meeting.defaultTemplate")
        defaults.set("Only list decisions.", forKey: "meeting.summaryPrompt")
        let s = settings()
        #expect(s.customSections.map(\.id) == [SummarySection.migratedID])
        #expect(s.customSections.map(\.heading) == ["My notes"])
        #expect(s.defaultSectionIDs == [SummarySection.migratedID])
    }

    @Test func theMigrationRunsOnce() throws {
        let s = settings()
        s.customPrompt = "Only list decisions."
        var mine = try #require(s.section(id: SummarySection.migratedID))
        mine.instruction = "Edited since."
        s.updateSection(mine)
        s.defaultSectionIDs = ["summary"]
        s.customPrompt = "A later change to the old setting."
        #expect(s.section(id: SummarySection.migratedID)?.instruction == "Edited since.")
        #expect(s.defaultSectionIDs == ["summary"])

        s.deleteSection(id: SummarySection.migratedID)
        #expect(s.customSections.isEmpty, "a deleted My notes does not come back")
    }

    @Test func anEmptyOrDefaultOldPromptMigratesNothing() {
        let empty = settings()
        #expect(empty.customSections.isEmpty)
        let same = MeetingSettings(defaults: UserDefaults(suiteName: "legato.meeting-settings.\(UUID().uuidString)")!)
        same.customPrompt = SummarySection.legacyDefaultPrompt
        #expect(same.customSections.isEmpty)
        #expect(same.defaultSectionIDs == ["summary", "decisions", "action-items"])
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
