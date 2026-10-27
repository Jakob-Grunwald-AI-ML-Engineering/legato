import Foundation
import Testing
@testable import LegatoMeetings

@Suite struct SummaryTemplateTests {
    @Test func theBuiltInsAreSummaryActionItemsEmailFollowUpOneOnOneAndBrainstorm() {
        #expect(SummaryTemplate.builtIns.map(\.name) == ["Summary", "Action items", "Email follow-up", "1:1 notes", "Brainstorm"])
        #expect(SummaryTemplate.builtIns.map(\.id) == ["summary", "action-items", "email-follow-up", "one-on-one", "brainstorm"])
        #expect(SummaryTemplate.builtIns.allSatisfy { $0.isBuiltIn })
        #expect(Set(SummaryTemplate.builtIns.map(\.prompt)).count == 5, "every template has its own instructions")
        #expect(SummaryTemplate.builtIns.allSatisfy { !$0.prompt.isEmpty })
    }

    @Test func theSummaryTemplateIsTheCurrentDefaultPrompt() {
        #expect(SummaryTemplate.summary.prompt == MeetingSummarizer.defaultPrompt)
        #expect(SummaryTemplate.summaryID == "summary")
    }

    @Test func templatesAreFoundByIDBuiltInsFirstThenCustom() {
        let mine = SummaryTemplate(id: "t-1", name: "Standup", prompt: "List blockers.")
        #expect(SummaryTemplate.find("action-items", custom: [mine])?.name == "Action items")
        #expect(SummaryTemplate.find("t-1", custom: [mine]) == mine)
        #expect(SummaryTemplate.find("gone", custom: [mine]) == nil)
        #expect(!mine.isBuiltIn)
    }

    @Test func aLegacyCustomPromptBecomesMyTemplate() {
        let migrated = SummaryTemplate.migratingLegacyPrompt("Write haiku.", into: [])
        #expect(migrated.count == 1)
        #expect(migrated[0].name == "My template" && migrated[0].prompt == "Write haiku." && !migrated[0].isBuiltIn)
    }

    @Test func aBlankOrDefaultLegacyPromptMigratesNothing() {
        #expect(SummaryTemplate.migratingLegacyPrompt("", into: []).isEmpty)
        #expect(SummaryTemplate.migratingLegacyPrompt("  \n", into: []).isEmpty)
        #expect(SummaryTemplate.migratingLegacyPrompt(MeetingSummarizer.defaultPrompt, into: []).isEmpty)
    }

    @Test func migrationRunsOnceAndKeepsOtherTemplates() {
        let other = SummaryTemplate(id: "t-1", name: "Standup", prompt: "List blockers.")
        let once = SummaryTemplate.migratingLegacyPrompt("Write haiku.", into: [other])
        #expect(once.map(\.name) == ["Standup", "My template"])
        let twice = SummaryTemplate.migratingLegacyPrompt("Write haiku.", into: once)
        #expect(twice == once)
        let edited = once.map { $0.name == "My template" ? SummaryTemplate(id: $0.id, name: "My template", prompt: "Edited.") : $0 }
        #expect(SummaryTemplate.migratingLegacyPrompt("Write haiku.", into: edited) == edited, "never overwrites an edit")
    }

    @Test func templatesRoundTripThroughJSON() throws {
        let t = SummaryTemplate(id: "t-1", name: "Standup", prompt: "List blockers.")
        let back = try JSONDecoder().decode(SummaryTemplate.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}
