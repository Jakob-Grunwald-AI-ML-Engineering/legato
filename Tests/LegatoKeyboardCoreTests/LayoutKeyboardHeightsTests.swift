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

    @Test func portraitAddsOneNativeToolRowBelowNativePredictions() {
        // iOS 26 adds 17 pt above the extension in portrait. Request only the remaining 27 pt of the native 44 pt.
        // Native Q starts 8 pt below the complete visible prediction row.
        // The tools add one native 54 pt key pitch before the unchanged typing grid.
        #expect(KeyboardHeights.wordRowHeight(landscape: false) == 27)
        #expect(KeyboardHeights.pillHeight(landscape: false) == 43)
        #expect(KeyboardHeights.pillGapToRow(landscape: false) == 11)
        #expect(KeyboardHeights.firstRowTop(landscape: false) == 89)
        #expect(KeyboardHeights.height(landscape: false) == 297)
    }

    @Test func landscapeKeyRowsAlignWithTheNativeScreenBottom() {
        // iPhone 17 landscape: native first row y244, last face ends377; system area starts381.
        let firstFaceTop = 381 - KeyboardHeights.height(landscape: true)
            + KeyboardHeights.firstRowTop(landscape: true)
        #expect(abs(firstFaceTop - 244) <= 1)
        #expect(abs(firstFaceTop + 3 * 35.33 + 27.33 - 377) <= 1)
    }

    @Test func landscapeAddsOneNativeToolRowBelowNativePredictions() {
        // Physical iPhone: predictions y194..238, first letter face y244.
        #expect(KeyboardHeights.wordRowHeight(landscape: true) == 44)
        #expect(KeyboardHeights.pillHeight(landscape: true) == 27.33)
        #expect(KeyboardHeights.pillGapToRow(landscape: true) == 8)
        #expect(abs(KeyboardHeights.firstRowTop(landscape: true) - 85.33) < 0.0001)
        #expect(abs(KeyboardHeights.height(landscape: true) - 222.65) < 0.0001)
    }

    @Test func compactLandscapeContainsPredictionsAndOneNativeLandscapeKeyRow() {
        // Predictions 44, then 6 pt top gap, 27.33 pt face and 4 pt bottom gap.
        #expect(abs(StripHeight.keyRowHeight(row: 54, landscape: true) - 37.33) < 0.0001)
        #expect(abs(StripHeight.requested(row: 54, landscape: true) - 81.33) < 0.0001)
    }

    @Test func portraitPredictionContentExcludesTheSystemRoundedTopArea() {
        // Retained before image: visible predictions 61 pt; native 44 pt. Public safe-area/style changes had no effect.
        #expect(KeyboardHeights.height(landscape: false) - KeyboardHeights.firstRowTop(landscape: false) == 208)
        #expect(KeyboardHeights.toolRowTop(landscape: false) == 35)
        // The compositor supplies 17 pt; requesting 27 pt makes the visible row 44 pt without moving the typing grid.
        #expect(KeyboardHeights.wordRowHeight(landscape: false) + 17 == 44)
        #expect(KeyboardHeights.wordRowHeight(landscape: true) == 44)
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
        #expect(WordRowHeight.strip == 27)
        #expect(StripHeight.requested(row: 54) == 81)
        #expect(StripHeight.resolve(stored: 56) == 54)
        #expect(StripHeight.resolve(stored: 44) == 54)
        #expect(StripHeight.requested(row: 30) == 57)
    }

    @Test func theDebugHeightsThatLeaveNothingToTouchStayAsRequested() {
        #expect(StripHeight.requested(row: 0) == 0)
        #expect(StripHeight.requested(row: 1) == 1)
    }
}

@Suite struct ComposerKeyboardSizeTests {
    @Test func threeHeightsIncludeNativeTrayWithinFullScreenBudget() {
        #expect(ComposerKeyboardSize.low.height(screenHeight: 874, systemOverhead: 92) == 82)
        #expect(ComposerKeyboardSize.medium.height(screenHeight: 874, systemOverhead: 92) == 243)
        #expect(abs(ComposerKeyboardSize.full.height(screenHeight: 874, systemOverhead: 92) - 650.9) < 0.01)
        #expect(ComposerKeyboardSize.full.height(screenHeight: 402, systemOverhead: 21, landscape: true) < 342)
        #expect(ComposerKeyboardSize.full.height(screenHeight: 100, systemOverhead: 92) == 0)
    }

    @Test func eachSwipeMovesExactlyOnePresetAndClampsAtBothEnds() {
        #expect(ComposerKeyboardSize.low.swiped(dx: 0, dy: -300) == .medium)
        #expect(ComposerKeyboardSize.medium.swiped(dx: 0, dy: -300) == .full)
        #expect(ComposerKeyboardSize.full.swiped(dx: 0, dy: -300) == .full)
        #expect(ComposerKeyboardSize.full.swiped(dx: 0, dy: 300) == .medium)
        #expect(ComposerKeyboardSize.medium.swiped(dx: 0, dy: 300) == .low)
        #expect(ComposerKeyboardSize.low.swiped(dx: 0, dy: 300) == .low)
        #expect(ComposerKeyboardSize.medium.swiped(dx: 40, dy: -30) == .medium)
        #expect(ComposerKeyboardSize.medium.swiped(dx: 0, dy: -15) == .medium)
    }

    @Test func tapCyclesAndStoredPresetRestores() {
        #expect(ComposerKeyboardSize.full.cycled == .low)
        #expect(ComposerKeyboardSize.low.cycled == .medium)
        #expect(ComposerKeyboardSize(rawValue: "full") == .full)
    }
}
