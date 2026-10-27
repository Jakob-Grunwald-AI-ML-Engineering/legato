import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutKeyboardHeightsTests {
    @Test func portraitGrowsByTheShortfallSoTheWordRowFitsAbovePill() {
        // Today: pill top = 86 - 15.7 - 43.3 = 27 pt below the keyboard top; the word row needs 32.
        #expect(KeyboardHeights.wordRowHeight(landscape: false) == 32)
        #expect(KeyboardHeights.firstRowTop(landscape: false) == 91)
        #expect(KeyboardHeights.height(landscape: false) == 306)
    }

    @Test func thePillKeepsItsSizeAndTheWordRowFitsAboveIt() {
        let top = KeyboardHeights.firstRowTop(landscape: false)
        let pillTop = top - KeyboardHeights.pillGapToRow(landscape: false) - KeyboardHeights.pillHeight(landscape: false)
        #expect(KeyboardHeights.pillHeight(landscape: false) == 43.3)
        #expect(pillTop >= KeyboardHeights.wordRowHeight(landscape: false) - 0.0001)
    }

    @Test func landscapeIsUnchangedAndTheWordRowSharesThePillsRow() {
        #expect(KeyboardHeights.firstRowTop(landscape: true) == 51)
        #expect(KeyboardHeights.height(landscape: true) == 51 + 3 * 35.33 + 25.33 + 8)
        #expect(KeyboardHeights.wordRowHeight(landscape: true) == 0)
    }

    @Test func theRowsBelowTheBarKeepTheirHeight() {
        let rows = KeyboardHeights.height(landscape: false) - KeyboardHeights.firstRowTop(landscape: false)
        #expect(rows == 3 * 54 + 43 + 10)
    }

    @Test func theStripGrowsByTheWordRow() {
        #expect(WordRowHeight.strip == 30)
        #expect(StripHeight.requested(row: 44) == 74)
        #expect(StripHeight.requested(row: 56) == 86)
        #expect(StripHeight.requested(row: 30) == 60)
    }

    @Test func theDebugHeightsThatLeaveNothingToTouchStayAsRequested() {
        #expect(StripHeight.requested(row: 0) == 0)
        #expect(StripHeight.requested(row: 1) == 1)
    }
}
