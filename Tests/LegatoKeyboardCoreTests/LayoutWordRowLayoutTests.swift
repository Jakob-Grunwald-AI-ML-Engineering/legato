import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutWordRowLayoutTests {
    @Test func slotsNeedAtLeastTheirMinimumWidthEach() {
        #expect(WordRowLayout.visibleSlots(width: 3 * WordRowLayout.minSlotWidth) == 3)
        #expect(WordRowLayout.visibleSlots(width: 700) == 3)
        #expect(WordRowLayout.visibleSlots(width: 3 * WordRowLayout.minSlotWidth - 0.1) == 2)
        #expect(WordRowLayout.visibleSlots(width: 2 * WordRowLayout.minSlotWidth) == 2)
    }

    @Test func narrowerThanTwoSlotsOnlyTheBestWordShows() {
        #expect(WordRowLayout.visibleSlots(width: 2 * WordRowLayout.minSlotWidth - 0.1) == 1)
        #expect(WordRowLayout.visibleSlots(width: 0) == 1)
    }

    @Test func theTranscriptBesideTheDictationKeyShowsTwoSlotsOnAPortraitPhone() {
        // iPhone 17 (402 pt): the transcript is 402 - 6.33 margin - 93 key - 3 (half a gap) wide.
        #expect(WordRowLayout.visibleSlots(width: 402 - 6.33 - 93 - 3) == 2)
    }

    @Test func slotsRunInRankOrder() {
        #expect(WordRowLayout.ranks(visibleSlots: 3) == [1, 0, 2])
        #expect(WordRowLayout.ranks(visibleSlots: 2) == [0, 1])
        #expect(WordRowLayout.ranks(visibleSlots: 1) == [0])
    }

    @Test func theCornerInsetSitsOnTheSideAwayFromTheDictationKey() {
        #expect(WordRowLayout.previewInset >= WordRowLayout.contentInset)
        #expect(WordRowLayout.previewInset == 16)
        let right = WordRowLayout.insets(keySide: .right), left = WordRowLayout.insets(keySide: .left)
        #expect(right.leading == 16 && right.trailing == 8)
        #expect(left.leading == 8 && left.trailing == 16)
    }
}
