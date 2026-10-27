import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutWordRowLayoutTests {
    @Test func threeSlotsNeedAtLeastSeventyPointsEach() {
        #expect(WordRowLayout.minSlotWidth == 70)
        #expect(WordRowLayout.visibleSlots(width: 210) == 3)
        #expect(WordRowLayout.visibleSlots(width: 460) == 3)
    }

    @Test func narrowerThanThatOnlyTheBestWordShows() {
        #expect(WordRowLayout.visibleSlots(width: 209.9) == 1)
        #expect(WordRowLayout.visibleSlots(width: 0) == 1)
    }

    @Test func threeSlotsRunSecondBestThirdLeftToRight() {
        #expect(WordRowLayout.ranks(visibleSlots: 3) == [1, 0, 2])
        #expect(WordRowLayout.ranks(visibleSlots: 1) == [0])
    }
}
