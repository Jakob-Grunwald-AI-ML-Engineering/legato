import Foundation
import LegatoMeetings
import Testing
@testable import LegatoAppServices

/// Settings hold the sections (built in and custom), their order and the default ticks.
@Suite struct MeetingSettingsSectionTests {
    private let suite = "legato.meeting-settings.\(UUID().uuidString)"
    private func settings() -> MeetingSettings { MeetingSettings(defaults: UserDefaults(suiteName: suite)!) }
    private let builtInIDs = ["summary", "decisions", "action-items", "open-questions", "email-follow-up", "one-on-one", "brainstorm"]

    @Test func withNothingSetTheSectionsAreTheBuiltInsAndTheDefaultTicksAreSummaryDecisionsAndActionItems() {
        let s = settings()
        #expect(s.customSections.isEmpty)
        #expect(s.allSections.map(\.id) == builtInIDs)
        #expect(s.defaultSectionIDs == ["summary", "decisions", "action-items"])
        #expect(s.section(id: "brainstorm")?.heading == "Brainstorm")
        #expect(s.section(id: "nope") == nil)
    }

    @Test func theAutomaticSummaryIsOnByDefaultAndPersists() {
        let s = settings()
        #expect(s.summarizeAutomatically)
        s.summarizeAutomatically = false
        #expect(!MeetingSettings(defaults: UserDefaults(suiteName: suite)!).summarizeAutomatically)
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
        let plain = Meeting(title: "T", date: Date())
        #expect(s.sections(for: plain).map(\.id) == ["decisions"], "nil: the default ticks")
        let ticked = Meeting(title: "T", date: Date(), sections: ["brainstorm", "gone", "summary"])
        #expect(s.sections(for: ticked).map(\.id) == ["summary", "brainstorm"])
    }

    @Test func togglingAChipTicksOrUnticksItInTheConfiguredOrder() {
        let s = settings()
        let plain = Meeting(title: "T", date: Date())  // the default ticks
        #expect(s.ticks(of: plain, toggling: "open-questions") == ["summary", "decisions", "action-items", "open-questions"])
        #expect(s.ticks(of: plain, toggling: "decisions") == ["summary", "action-items"])
        let mine = Meeting(title: "T", date: Date(), sections: ["brainstorm", "gone"])
        #expect(s.ticks(of: mine, toggling: "summary") == ["summary", "brainstorm"], "what is gone drops out")
        #expect(s.ticks(of: mine, toggling: "brainstorm") == [])
    }
}
