import Foundation
import Testing
@testable import LegatoMeetings

/// Jakob: "I would prefer to not have the templates as single-select. Multiple select of sections/items feels better."
/// A meeting ticks sections; its summary holds exactly the ticked ones, each under its own heading.
@Suite struct SummarySectionTests {
    @Test func theBuiltInsAreTheSevenSections() {
        #expect(SummarySection.builtIns.map(\.heading) == [
            "Summary", "Decisions", "Action items", "Open questions", "Email follow-up", "1:1 notes", "Brainstorm",
        ])
        #expect(SummarySection.builtIns.map(\.id) == [
            "summary", "decisions", "action-items", "open-questions", "email-follow-up", "one-on-one", "brainstorm",
        ])
        #expect(SummarySection.builtIns.allSatisfy { $0.isBuiltIn })
        #expect(Set(SummarySection.builtIns.map(\.instruction)).count == 7, "every section has its own instruction")
        #expect(SummarySection.builtIns.allSatisfy { !$0.instruction.isEmpty })
    }

    @Test func theDefaultTicksAreSummaryDecisionsAndActionItems() {
        #expect(SummarySection.defaultIDs == ["summary", "decisions", "action-items"])
    }

    @Test func sectionsAreFoundByIDBuiltInsFirstThenCustom() {
        let mine = SummarySection(id: "c-1", heading: "Blockers", instruction: "List blockers.")
        #expect(SummarySection.find("decisions", custom: [mine])?.heading == "Decisions")
        #expect(SummarySection.find("c-1", custom: [mine]) == mine)
        #expect(SummarySection.find("gone", custom: [mine]) == nil)
        #expect(!mine.isBuiltIn)
    }

    @Test func resolvingKeepsTheCatalogsOrderAndDropsWhatIsGone() {
        let catalog = SummarySection.builtIns
        let resolved = SummarySection.resolve(["action-items", "gone", "summary"], in: catalog)
        #expect(resolved.map(\.id) == ["summary", "action-items"], "the configured order, not the tick order")
    }

    @Test func theInstructionsHoldExactlyTheTickedSectionsAsHeadingsInOrder() throws {
        let decisions = try #require(SummarySection.find("decisions", custom: []))
        let actions = try #require(SummarySection.find("action-items", custom: []))
        let text = SummarySection.instructions(for: [decisions, actions])
        let d = try #require(text.range(of: "## Decisions"))
        let a = try #require(text.range(of: "## Action items"))
        #expect(d.lowerBound < a.lowerBound)
        #expect(text.contains(decisions.instruction) && text.contains(actions.instruction))
        for other in SummarySection.builtIns where other.id != "decisions" && other.id != "action-items" {
            #expect(!text.contains("## \(other.heading)"), "no \(other.heading) section")
        }
        #expect(text.localizedCaseInsensitiveContains("same language"))
        #expect(text.localizedCaseInsensitiveContains("speaker"))
    }

    @Test func aCustomSectionIsWrittenUnderItsOwnHeading() {
        let mine = SummarySection(id: "c-1", heading: "Risks", instruction: "Bullets for each risk named.")
        let text = SummarySection.instructions(for: [mine])
        #expect(text.contains("## Risks\nBullets for each risk named."))
    }

    @Test func eachOldTemplateMapsOntoItsSections() {
        #expect(SummarySection.sections(forTemplate: "summary") == ["summary", "decisions", "action-items"])
        #expect(SummarySection.sections(forTemplate: "action-items") == ["action-items"])
        #expect(SummarySection.sections(forTemplate: "email-follow-up") == ["email-follow-up"])
        #expect(SummarySection.sections(forTemplate: "one-on-one") == ["one-on-one"])
        #expect(SummarySection.sections(forTemplate: "brainstorm") == ["brainstorm"])
        #expect(SummarySection.sections(forTemplate: "my-template") == [SummarySection.migratedID])
        #expect(SummarySection.sections(forTemplate: "custom-abc") == ["custom-abc"], "a custom template became a custom section")
    }

    @Test func aLegacyCustomPromptBecomesTheMyNotesSection() throws {
        let migrated = SummarySection.migratingLegacyPrompt("Write haiku.", into: [])
        #expect(migrated.count == 1)
        let mine = try #require(migrated.first)
        #expect(mine.heading == "My notes" && mine.instruction == "Write haiku." && !mine.isBuiltIn)
        #expect(mine.id == SummarySection.migratedID)
    }

    @Test func aBlankOrDefaultLegacyPromptMigratesNothing() {
        #expect(SummarySection.migratingLegacyPrompt("", into: []).isEmpty)
        #expect(SummarySection.migratingLegacyPrompt("  \n", into: []).isEmpty)
        #expect(SummarySection.migratingLegacyPrompt(SummarySection.legacyDefaultPrompt, into: []).isEmpty)
    }

    @Test func migrationRunsOnceAndKeepsOtherSections() {
        let other = SummarySection(id: "c-1", heading: "Blockers", instruction: "List blockers.")
        let once = SummarySection.migratingLegacyPrompt("Write haiku.", into: [other])
        #expect(once.map(\.heading) == ["Blockers", "My notes"])
        let twice = SummarySection.migratingLegacyPrompt("Write haiku.", into: once)
        #expect(twice == once)
        let edited = once.map { $0.id == SummarySection.migratedID ? SummarySection(id: $0.id, heading: "My notes", instruction: "Edited.") : $0 }
        #expect(SummarySection.migratingLegacyPrompt("Write haiku.", into: edited) == edited, "never overwrites an edit")
    }

    @Test func sectionsRoundTripThroughJSON() throws {
        let s = SummarySection(id: "c-1", heading: "Blockers", instruction: "List blockers.")
        let back = try JSONDecoder().decode(SummarySection.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
