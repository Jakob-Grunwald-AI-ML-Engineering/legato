import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutKeyboardHeightsTests {
    @Test func portraitKeyFacesAlignWithNativeKeyboardAtTheSameScreenBottom() {
        // iPhone 17, iOS 26.5: native Q face starts at 591 pt, keyboard content ends at 799 pt.
        // A 306 pt request placed every Legato face 7 pt above the native rows.
        let contentBottom = 799.0
        let firstFaceTop = contentBottom - KeyboardHeights.height(landscape: false)
            + KeyboardHeights.firstRowTop(landscape: false)
        #expect(firstFaceTop == 591)
        #expect(firstFaceTop + 3 * 54 + 43 == 796)
    }

    @Test func portraitGrowsByTheShortfallSoTheWordRowFitsAbovePill() {
        // Today: pill top = 86 - 15.7 - 43.3 = 27 pt below the keyboard top; the word row needs 32.
        #expect(KeyboardHeights.wordRowHeight(landscape: false) == 32)
        #expect(KeyboardHeights.firstRowTop(landscape: false) == 91)
        #expect(KeyboardHeights.height(landscape: false) == 299)
    }

    @Test func thePillKeepsItsSizeAndTheWordRowFitsAboveIt() {
        let top = KeyboardHeights.firstRowTop(landscape: false)
        let pillTop = top - KeyboardHeights.pillGapToRow(landscape: false) - KeyboardHeights.pillHeight(landscape: false)
        #expect(KeyboardHeights.pillHeight(landscape: false) == 43.3)
        #expect(pillTop >= KeyboardHeights.wordRowHeight(landscape: false) - 0.0001)
    }

    @Test func landscapeKeyRowsAlignWithTheNativeScreenBottom() {
        // iPhone 17 landscape: native first row y244, last face ends377; system area starts381.
        let firstFaceTop = 381 - KeyboardHeights.height(landscape: true)
            + KeyboardHeights.firstRowTop(landscape: true)
        #expect(abs(firstFaceTop - 244) <= 1)
        #expect(abs(firstFaceTop + 3 * 35.33 + 27.33 - 377) <= 1)
    }

    @Test func landscapeKeepsTheSharedPillRowAndNativeKeyHeight() {
        #expect(KeyboardHeights.firstRowTop(landscape: true) == 51)
        #expect(KeyboardHeights.height(landscape: true) == 51 + 3 * 35.33 + 27.33 + 4)
        #expect(KeyboardHeights.wordRowHeight(landscape: true) == 0)
    }

    @Test func portraitRowsKeepNativePitchAndThreePointBottomGap() {
        let rows = KeyboardHeights.height(landscape: false) - KeyboardHeights.firstRowTop(landscape: false)
        #expect(rows == 3 * 54 + 43 + 3)
    }

    @Test func landscapeSubtractsOnlyTheSystemProvidedSideInset() {
        #expect(KeyboardSideMargins.landscape(contentWidth: 724, screenWidth: 874) == 4)
        #expect(KeyboardSideMargins.landscape(contentWidth: 874, screenWidth: 874) == 79)
        #expect(KeyboardSideMargins.landscape(contentWidth: 844, screenWidth: 962) == 20)
        #expect(KeyboardSideMargins.landscape(contentWidth: 874, screenWidth: nil) == 79)
        #expect(KeyboardSideMargins.landscape(contentWidth: 874, screenWidth: 402) == 79)
    }

    @Test func theStripGrowsByTheWordRow() {
        #expect(WordRowHeight.strip == 40)
        #expect(StripHeight.requested(row: 44) == 84)
        #expect(StripHeight.requested(row: 56) == 96)
        #expect(StripHeight.requested(row: 30) == 70)
    }

    @Test func theDebugHeightsThatLeaveNothingToTouchStayAsRequested() {
        #expect(StripHeight.requested(row: 0) == 0)
        #expect(StripHeight.requested(row: 1) == 1)
    }
}
