import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutStripRowTests {
    private func row(_ width: Double, globe: Bool = false, returnStyle: StripReturnStyle = .glyph) -> StripRow {
        StripRow.make(width: width, showsGlobe: globe, returnStyle: returnStyle)
    }

    private func cell(_ row: StripRow, _ slot: StripSlot) -> StripCell {
        row.cells.first { $0.slot == slot }!
    }

    // MARK: order

    @Test func theRowIsChevronHotkeysDeleteReturnMic() {
        #expect(row(402).cells.map(\.slot) == [.expand, .hotkeys, .delete, .returnKey, .mic])
    }

    @Test func theGlobeSitsRightOfTheChevronWhenIOSAsksForIt() {
        #expect(row(402, globe: true).cells.map(\.slot) == [.expand, .globe, .hotkeys, .delete, .returnKey, .mic])
    }

    // MARK: sizes on a regular phone

    @Test func onARegularPhoneKeysAreStandardAndTheMicIsTheFullPill() {
        let r = row(402)
        #expect(cell(r, .expand).width == 44)
        #expect(cell(r, .delete).width == 44)
        #expect(cell(r, .returnKey).width == 44)
        #expect(cell(r, .mic).width == 81)
    }

    @Test func theMicPillStaysRightAnchoredAtTheMargin() {
        let r = row(402)
        #expect(cell(r, .mic).maxX == 402 - 8)
    }

    @Test func theHotkeysTakeWhatTheControlsLeave() {
        // 402 - 2 x 8 margin - 4 gaps x 8 - 3 keys x 44 - pill 81
        #expect(cell(row(402), .hotkeys).width == 141)
    }

    @Test func aTextReturnLabelGetsAWiderKey() {
        let r = row(402, returnStyle: .text)
        #expect(cell(r, .returnKey).width == StripRow.textReturnWidth)
        #expect(cell(r, .delete).width == 44)
    }

    // MARK: fitting

    @Test func cellsAreSeparatedByTheGapAndStayInsideTheMargins() {
        for width in [375.0, 402, 430, 874] {
            let r = row(width, globe: true)
            #expect(r.cells.first!.x == 8)
            #expect(r.cells.last!.maxX == width - 8)
            for (a, b) in zip(r.cells, r.cells.dropFirst()) {
                #expect(abs(b.x - a.maxX - 8) < 0.0001)
            }
        }
    }

    @Test func aNarrowPhoneWithAGlobeShrinksTheKeysToKeepTheHotkeysFitting() {
        // 375 with a globe and a text return: keys at 44 would leave the hotkeys 46 wide.
        let r = row(375, globe: true, returnStyle: .text)
        #expect(cell(r, .hotkeys).width >= StripRow.minHotkeysWidth - 0.0001)
        #expect(cell(r, .expand).width < 44)
        #expect(cell(r, .mic).width == 81)
    }

    @Test func theHotkeysMinimumIsThreeButtons() {
        #expect(StripRow.minHotkeysWidth == 3 * StripRow.hotkeyButtonWidth)
        #expect(StripRow.hotkeyButtonWidth == 36)
    }

    @Test func theHotkeysAlwaysGetTheirMinimumFromThePhoneSizesUp() {
        for width in stride(from: 375.0, through: 932, by: 1) {
            for globe in [false, true] {
                for style in [StripReturnStyle.glyph, .text] {
                    #expect(cell(row(width, globe: globe, returnStyle: style), .hotkeys).width >= StripRow.minHotkeysWidth - 0.0001, "w=\(width) globe=\(globe) \(style)")
                }
            }
        }
    }

    @Test func atTheSmallestWidthTheHotkeysStillFitAndTheMicKeepsItsSize() {
        // iPhone SE 1st gen, 320 pt, with the globe: the keys give up space, the hotkeys do not.
        let r = row(320, globe: true)
        #expect(cell(r, .hotkeys).width >= StripRow.minHotkeysWidth - 0.0001)
        #expect(cell(r, .mic).width == 81)
        #expect(cell(r, .mic).maxX == 320 - 8)
    }

    @Test func theHotkeysWidthWithoutAGlobeAtTheSmallestWidth() {
        // 320 - 16 - 32 - 132 - 81 = 59 would be left; the hotkeys take 108 and the keys shrink to (183 - 108) / 3.
        let r = row(320)
        #expect(cell(r, .hotkeys).width == StripRow.minHotkeysWidth)
        #expect(abs(cell(r, .expand).width - (320 - 16 - 32 - 81 - 108) / 3) < 0.0001)
    }

    @Test func everyWidthFromSEToLandscapeFitsWithAMicPillOfFullSize() {
        for width in stride(from: 320.0, through: 932, by: 4) {
            for globe in [false, true] {
                for style in [StripReturnStyle.glyph, .text] {
                    let r = row(width, globe: globe, returnStyle: style)
                    #expect(r.cells.first!.x >= 8 - 0.0001, "w=\(width)")
                    #expect(r.cells.last!.maxX <= width - 8 + 0.0001, "w=\(width) globe=\(globe) \(style)")
                    #expect(cell(r, .mic).width == 81, "w=\(width)")
                    #expect(cell(r, .hotkeys).width >= StripRow.minHotkeysWidth - 0.0001, "w=\(width)")
                    for slot in [StripSlot.expand, .delete, .returnKey] {
                        #expect(cell(r, slot).width > 0, "w=\(width) \(slot)")
                    }
                }
            }
        }
    }

    // MARK: hit areas

    @Test func hitAreasTileTheWholeRowWithoutOverlap() {
        for width in [320.0, 375, 402, 874] {
            let r = row(width, globe: true)
            #expect(r.cells.first!.hitX == 0)
            #expect(abs(r.cells.last!.hitMaxX - width) < 0.0001)
            for (a, b) in zip(r.cells, r.cells.dropFirst()) {
                #expect(abs(a.hitMaxX - b.hitX) < 0.0001, "w=\(width)")
            }
        }
    }

    @Test func everyHitAreaContainsItsKeyAndTheGapsAreSplitInTheMiddle() {
        let r = row(402, globe: true)
        for c in r.cells {
            #expect(c.hitX <= c.x + 0.0001)
            #expect(c.hitMaxX >= c.maxX - 0.0001)
        }
        let delete = cell(r, .delete), ret = cell(r, .returnKey)
        #expect(delete.hitMaxX == delete.maxX + 4)
        #expect(ret.hitX == ret.x - 4)
    }

    @Test func theMicHitAreaReachesTheRightScreenEdge() {
        let r = row(402)
        let mic = cell(r, .mic)
        #expect(mic.hitMaxX == 402)
        #expect(mic.hitWidth == 4 + 81 + 8)
    }

    @Test func theChevronHitAreaReachesTheLeftScreenEdge() {
        #expect(cell(row(402), .expand).hitX == 0)
    }

    @Test func insetsAreTheDistanceFromTheHitAreaToTheKey() {
        let c = cell(row(402), .mic)
        #expect(c.leadingInset == 4)
        #expect(c.trailingInset == 8)
        #expect(cell(row(402), .expand).leadingInset == 8)
    }
}
