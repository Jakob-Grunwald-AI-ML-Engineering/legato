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

    @Test func landscapeKeyRowsAlignWithTheNativeScreenBottom() {
        // iPhone 17 landscape: native first row y244, last face ends377; system area starts381.
        let firstFaceTop = 381 - KeyboardHeights.height(landscape: true)
            + KeyboardHeights.firstRowTop(landscape: true)
        #expect(abs(firstFaceTop - 244) <= 1)
        #expect(abs(firstFaceTop + 3 * 35.33 + 27.33 - 377) <= 1)
    }

    @Test func portraitIsOneTopRowAboveTheNativeGrid() {
        // #315: the word row and the tool row became one row; the first grid row sits as high as its popups allow.
        #expect(KeyboardHeights.firstRowTop(landscape: false) == 67)
        #expect(KeyboardHeights.keyFaceTop(landscape: false) == 13)
        #expect(KeyboardHeights.height(landscape: false) == 275)
        #expect(KeyboardHeights.height(landscape: false) - KeyboardHeights.firstRowTop(landscape: false) == 3 * 54 + 43 + 3)
    }

    @Test func landscapeIsOneTopRowAboveTheNativeGrid() {
        #expect(KeyboardHeights.firstRowTop(landscape: true) == 45)
        #expect(abs(KeyboardHeights.keyFaceTop(landscape: true) - 9.67) < 0.0001)
        #expect(abs(KeyboardHeights.height(landscape: true) - 182.32) < 0.0001)
    }

    @Test func theTopRowsPopupsStayInsideTheView() {
        for landscape in [false, true] {
            #expect(KeyboardHeights.firstRowTop(landscape: landscape) >= KeyboardHeights.popupReach(landscape: landscape))
            #expect(KeyboardHeights.firstRowTop(landscape: landscape) - KeyboardHeights.popupReach(landscape: landscape) < 1)
        }
    }

    @Test func minimisedIsTwoRowsOfKeysWithTheirNativePitch() {
        #expect(KeyboardHeights.minimisedHeight(landscape: false) == 13 + 54 + 43 + 3)
        #expect(abs(KeyboardHeights.minimisedHeight(landscape: true) - (9.67 + 35.33 + 27.33 + 4)) < 0.0001)
        #expect(KeyboardHeights.requested(mode: .minimised, landscape: false) == 113)
        #expect(KeyboardHeights.requested(mode: .full, landscape: false) == 275)
    }

    @Test func landscapeSubtractsOnlyTheSystemProvidedSideInset() {
        #expect(KeyboardSideMargins.landscape(contentWidth: 724, screenWidth: 874) == 4)
        #expect(KeyboardSideMargins.landscape(contentWidth: 874, screenWidth: 874) == 79)
        #expect(KeyboardSideMargins.landscape(contentWidth: 844, screenWidth: 962) == 20)
        #expect(KeyboardSideMargins.landscape(contentWidth: 874, screenWidth: nil) == 79)
        #expect(KeyboardSideMargins.landscape(contentWidth: 874, screenWidth: 402) == 79)
    }
}

@Test func thePreviewFontFitsTwoLinesInTheTranscriptAsItIs() {
    // Portrait: the 43 pt top row holds two lines of 13 pt (31.2 + 1.3 spacing + 2 x 1 pt padding = 34.5). Landscape keys are
    // 27.33 pt: the transcript keeps the 30 pt that holds 11 pt (26.4 + 1.1 + 2 = 29.5; 12 pt needs 32).
    #expect(WordRowHeight.previewFontSize(rowHeight: 43) == 13)
    #expect(WordRowHeight.previewFontSize(rowHeight: WordRowHeight.minimumRow) == 11)
    let size = WordRowHeight.previewFontSize(rowHeight: WordRowHeight.minimumRow)
    let pad = WordRowHeight.previewPadding(rowHeight: WordRowHeight.minimumRow, size: size)
    #expect(WordRowHeight.previewContentHeight(size: size) + 2 * pad <= WordRowHeight.minimumRow && pad >= WordRowHeight.previewMinPadding)
    #expect(WordRowHeight.previewLineSpacing(size: size) > 0, "the two lines breathe")
    #expect(WordRowHeight.previewIsSingleLine(textHeight: WordRowHeight.previewLineHeight(size: 11), size: 11))
    #expect(!WordRowHeight.previewIsSingleLine(textHeight: 2 * WordRowHeight.previewLineHeight(size: 11), size: 11))
    #expect(WordRowHeight.previewTruncated(textHeight: 40, rowHeight: 30, prefixed: false))
    #expect(WordRowHeight.previewTruncated(textHeight: 20, rowHeight: 30, prefixed: true))
    #expect(!WordRowHeight.previewTruncated(textHeight: 27.5, rowHeight: 30, prefixed: false))
}
