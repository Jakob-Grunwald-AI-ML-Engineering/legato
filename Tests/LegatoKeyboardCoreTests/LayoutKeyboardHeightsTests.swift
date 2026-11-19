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
        // iOS 26 adds 17 pt above the extension in portrait. Request the remaining 27 pt of the native 44 pt plus 3 pt of
        // room for the two-line dictation preview (#313): 30 pt.
        // Native Q starts 8 pt below the complete visible prediction row.
        // The tools add one native 54 pt key pitch before the unchanged typing grid.
        #expect(KeyboardHeights.wordRowHeight(landscape: false) == 30)
        #expect(KeyboardHeights.pillHeight(landscape: false) == 43)
        #expect(KeyboardHeights.pillGapToRow(landscape: false) == 11)
        #expect(KeyboardHeights.firstRowTop(landscape: false) == 92)
        #expect(KeyboardHeights.height(landscape: false) == 300)
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
        #expect(KeyboardHeights.toolRowTop(landscape: false) == 38)
        // The compositor supplies 17 pt; requesting 30 pt makes the visible row 47 pt (the native 44 pt plus the preview's room)
        // and the typing grid keeps its place (the first-face test above).
        #expect(KeyboardHeights.wordRowHeight(landscape: false) + 17 == 44 + WordRowHeight.portraitPreviewRoom)
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
        #expect(WordRowHeight.strip == 30)
        #expect(StripHeight.requested(row: 54) == 84)
        #expect(StripHeight.resolve(stored: 56) == 54)
        #expect(StripHeight.resolve(stored: 44) == 54)
        #expect(StripHeight.requested(row: 30) == 60)
    }

    @Test func theDebugHeightsThatLeaveNothingToTouchStayAsRequested() {
        #expect(StripHeight.requested(row: 0) == 0)
        #expect(StripHeight.requested(row: 1) == 1)
    }
}

@Test func thePreviewFontFitsTwoLinesInTheRowAsItIs() {
    // Portrait: 30 pt holds two lines of 11 pt with air (26.4 + 1.1 spacing + 2 x 1 pt padding = 29.5; 12 pt needs 32);
    // landscape's 44 pt holds 13 pt (31.2 + 1.3 + 2).
    #expect(WordRowHeight.previewFontSize(rowHeight: WordRowHeight.content(landscape: false)) == 11)
    #expect(WordRowHeight.previewFontSize(rowHeight: WordRowHeight.content(landscape: true)) == 13)
    let size = WordRowHeight.previewFontSize(rowHeight: WordRowHeight.portrait)
    let pad = WordRowHeight.previewPadding(rowHeight: WordRowHeight.portrait, size: size)
    #expect(WordRowHeight.previewContentHeight(size: size) + 2 * pad <= WordRowHeight.portrait && pad >= WordRowHeight.previewMinPadding)
    #expect(WordRowHeight.previewLineSpacing(size: size) > 0, "the two lines breathe")
    #expect(WordRowHeight.portrait == 30, "27 pt native extension row plus 3 pt for the preview")
    #expect(WordRowHeight.previewIsSingleLine(textHeight: WordRowHeight.previewLineHeight(size: 11), size: 11))
    #expect(!WordRowHeight.previewIsSingleLine(textHeight: 2 * WordRowHeight.previewLineHeight(size: 11), size: 11))
    #expect(WordRowHeight.previewTruncated(textHeight: 40, rowHeight: 30, prefixed: false))
    #expect(WordRowHeight.previewTruncated(textHeight: 20, rowHeight: 30, prefixed: true))
    #expect(!WordRowHeight.previewTruncated(textHeight: 27.5, rowHeight: 30, prefixed: false))
}
