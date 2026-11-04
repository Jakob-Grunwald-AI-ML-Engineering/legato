import Testing
@testable import LegatoMeetings

@Suite struct IslandExpansionTests {
    @Test func itIsCompactUntilSomethingExpandsIt() {
        #expect(IslandExpansion().isExpanded == false)
    }

    @Test func aStartedMeetingShowsTheFullCardForAFewSecondsThenCollapses() {
        var island = IslandExpansion()
        island.recordingStarted(at: 100)
        island.tick(at: 102.9)
        #expect(island.isExpanded)
        island.tick(at: 103)
        #expect(!island.isExpanded)
    }

    @Test func aClickOnThePillExpandsItUntilIdleOrAClickOutside() {
        var island = IslandExpansion()
        island.clicked(at: 10)
        island.tick(at: 15.9)
        #expect(island.isExpanded)
        island.tick(at: 16)
        #expect(!island.isExpanded)
        island.clicked(at: 20)
        island.clickedOutside()
        #expect(!island.isExpanded)
    }

    @Test func attentionExpandsItAndNeverShortensAnEarlierHold() {
        var island = IslandExpansion()
        island.clicked(at: 0)          // open until 6
        island.attention(at: 1)        // until 7
        island.tick(at: 6.5)
        #expect(island.isExpanded)
        island.recordingStarted(at: 6) // until 9 is later than 7
        island.tick(at: 8.5)
        #expect(island.isExpanded)
        island.tick(at: 9)
        #expect(!island.isExpanded)
    }

    @Test func aShortStartHoldDoesNotCutAnAttentionHold() {
        var island = IslandExpansion()
        island.attention(at: 0)        // until 6
        island.recordingStarted(at: 1) // until 4: ignored
        island.tick(at: 5)
        #expect(island.isExpanded)
    }

    @Test func resetReturnsToCompact() {
        var island = IslandExpansion()
        island.attention(at: 0)
        island.reset()
        #expect(!island.isExpanded)
        island.tick(at: 100)
        #expect(!island.isExpanded)
    }
}
