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
        #expect(abs(cell(r, .mic).maxX - 395.67) < 0.0001)
    }

    @Test func theHotkeysTakeWhatTheControlsLeave() {
        // 402 - 2 x 6.33 margin - 4 gaps x 6 - 3 keys x 44 - mic 81
        #expect(abs(cell(row(402), .hotkeys).width - 152.34) < 0.0001)
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
            #expect(r.cells.first!.x == 6.33)
            #expect(abs(r.cells.last!.maxX - (width - 6.33)) < 0.0001)
            for (a, b) in zip(r.cells, r.cells.dropFirst()) {
                #expect(abs(b.x - a.maxX - 6) < 0.0001)
            }
        }
    }

    @Test func aNarrowPhoneWithAGlobeKeepsTheKeysUsableAndDropsRedoForRoom() {
        // At 375 pt, a globe and text return require dropping redo to preserve key widths.
        let r = row(375, globe: true, returnStyle: .text)
        #expect(!r.showsRedo)
        #expect(cell(r, .hotkeys).width >= StripRow.minCompactHotkeysWidth - 0.0001)
        #expect(cell(r, .expand).width >= StripRow.minKeyWidth - 0.0001)
        #expect(cell(r, .mic).width == 81)
    }

    @Test func theHotkeyButtonsAreThirtyPointsAndTheKeyFloorIsThirtySix() {
        #expect(StripRow.hotkeyButtonWidth == 30)
        #expect(StripRow.minHotkeysWidth == 102)
        #expect(StripRow.minCompactHotkeysWidth == 66)
        #expect(StripRow.minKeyWidth == 36)
    }

    @Test func fromThePhoneSizesUpEveryKeyKeepsItsFloorAndTheHotkeysTheirRoom() {
        for width in stride(from: 375.0, through: 932, by: 1) {
            for globe in [false, true] {
                for style in [StripReturnStyle.glyph, .text] {
                    let r = row(width, globe: globe, returnStyle: style)
                    let need = r.showsRedo ? StripRow.minHotkeysWidth : StripRow.minCompactHotkeysWidth
                    #expect(cell(r, .hotkeys).width >= need - 0.0001, "w=\(width) globe=\(globe) \(style)")
                    for slot in [StripSlot.expand, .delete] + (style == .glyph ? [.returnKey] : []) + (globe ? [.globe] : []) {
                        #expect(cell(r, slot).width >= StripRow.minKeyWidth - 0.0001, "w=\(width) globe=\(globe) \(style) \(slot)")
                    }
                }
            }
        }
    }

    @Test func redoStaysWheneverThreeButtonsFitAtTheKeyFloor() {
        #expect(row(402).showsRedo)
        #expect(row(402, globe: true).showsRedo)
        #expect(row(430, globe: true, returnStyle: .text).showsRedo)
    }

    @Test func atTheSmallestWidthTheHotkeysStillFitAndTheMicKeepsItsSize() {
        // iPhone SE 1st gen, 320 pt, with the globe: below the phone sizes the keys give up space, the hotkeys do not.
        let r = row(320, globe: true)
        #expect(cell(r, .hotkeys).width >= StripRow.minCompactHotkeysWidth - 0.0001)
        #expect(cell(r, .mic).width == 81)
        #expect(abs(cell(r, .mic).maxX - 313.67) < 0.0001)
    }

    @Test func theNumbersAtTheSmallestCommonWidths() {
        // Native 6.33 pt margins and 6 pt gaps leave 191.34 pt for three keys and hotkeys.
        let narrow = row(375, globe: true, returnStyle: .text)
        #expect(abs(cell(narrow, .expand).width - 41.78) < 0.0001)
        #expect(abs(cell(narrow, .hotkeys).width - 66) < 0.0001)
        let se = row(320)
        #expect(!se.showsRedo)
        #expect(cell(se, .expand).width == 44)
        #expect(abs(cell(se, .hotkeys).width - 70.34) < 0.0001)
    }

    @Test func noKeyEverCollapsesToNothing() {
        for width in stride(from: 320.0, through: 932, by: 4) {
            for globe in [false, true] {
                for style in [StripReturnStyle.glyph, .text] {
                    let r = row(width, globe: globe, returnStyle: style)
                    for slot in [StripSlot.expand, .delete, .returnKey] {
                        #expect(cell(r, slot).width > 0, "w=\(width) \(slot)")
                    }
                }
            }
        }
    }

    @Test func everyWidthFromSEToLandscapeFitsWithAMicPillOfFullSize() {
        for width in stride(from: 320.0, through: 932, by: 4) {
            for globe in [false, true] {
                for style in [StripReturnStyle.glyph, .text] {
                    let r = row(width, globe: globe, returnStyle: style)
                    #expect(r.cells.first!.x >= 6.33 - 0.0001, "w=\(width)")
                    #expect(r.cells.last!.maxX <= width - 6.33 + 0.0001, "w=\(width) globe=\(globe) \(style)")
                    #expect(cell(r, .mic).width == 81, "w=\(width)")
                    #expect(cell(r, .hotkeys).width >= StripRow.minCompactHotkeysWidth - 0.0001, "w=\(width)")
                    let buttons = r.showsRedo ? 3.0 : 2.0
                    let actualButtonWidth = (cell(r, .hotkeys).width - (buttons - 1) * 6) / buttons
                    #expect(actualButtonWidth >= 30 - 0.0001, "w=\(width) globe=\(globe) \(style)")
                    if width >= 375 {
                        for slot in [StripSlot.expand, .delete, .returnKey] {
                            #expect(cell(r, slot).width >= StripRow.minKeyWidth - 0.0001, "w=\(width) globe=\(globe) \(style) \(slot)")
                        }
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
        #expect(delete.hitMaxX == delete.maxX + 3)
        #expect(ret.hitX == ret.x - 3)
    }

    @Test func theMicHitAreaReachesTheRightScreenEdge() {
        let r = row(402)
        let mic = cell(r, .mic)
        #expect(mic.hitMaxX == 402)
        #expect(abs(mic.hitWidth - 90.33) < 0.0001)
    }

    @Test func theChevronHitAreaReachesTheLeftScreenEdge() {
        #expect(cell(row(402), .expand).hitX == 0)
    }

    @Test func insetsAreTheDistanceFromTheHitAreaToTheKey() {
        let c = cell(row(402), .mic)
        #expect(abs(c.leadingInset - 3) < 0.0001)
        #expect(abs(c.trailingInset - 6.33) < 0.0001)
        #expect(cell(row(402), .expand).leadingInset == 6.33)
    }
}
