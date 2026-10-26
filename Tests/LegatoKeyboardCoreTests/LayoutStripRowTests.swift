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

    @Test func theRowIsChevronStatusDeleteReturnMic() {
        #expect(row(402).cells.map(\.slot) == [.expand, .status, .delete, .returnKey, .mic])
    }

    @Test func theGlobeSitsRightOfTheChevronWhenIOSAsksForIt() {
        #expect(row(402, globe: true).cells.map(\.slot) == [.expand, .globe, .status, .delete, .returnKey, .mic])
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

    @Test func theStatusTakesWhatTheControlsLeave() {
        // 402 - 2 x 8 margin - 4 gaps x 8 - 3 keys x 44 - pill 81
        #expect(cell(row(402), .status).width == 141)
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

    @Test func aNarrowPhoneWithAGlobeShrinksTheKeysToKeepTheStatusReadable() {
        // 375: keys at 44 would leave the status 62 wide with a globe; with a text return key 46.
        let r = row(375, globe: true, returnStyle: .text)
        let status = cell(r, .status)
        #expect(status.width >= StripRow.minStatusWidth - 0.0001)
        #expect(r.statusTextVisible)
        #expect(cell(r, .expand).width < 44)
        #expect(cell(r, .expand).width >= StripRow.minKeyWidth)
        #expect(cell(r, .mic).width == 81)
    }

    @Test func whenNoSpaceIsLeftForTheStatusTheKeysKeepTheirSizeAndTheStatusHides() {
        // iPhone SE 1st gen, 320 pt, with the globe: even at the smallest keys the status cannot get its minimum.
        let r = row(320, globe: true)
        #expect(!r.statusTextVisible)
        #expect(cell(r, .expand).width == 44)
        #expect(cell(r, .mic).width == 81)
        #expect(cell(r, .mic).maxX == 320 - 8)
        #expect(cell(r, .status).width >= 0)
    }

    @Test func theStatusShowsAtItsMinimumWidth() {
        // Without a globe 320 leaves 320 - 16 - 32 - 132 - 81 = 59.
        let r = row(320)
        #expect(r.statusTextVisible)
        #expect(cell(r, .status).width == 59)
    }

    @Test func everyWidthFromSEToLandscapeFitsWithAMicPillOfFullSize() {
        for width in stride(from: 320.0, through: 932, by: 4) {
            for globe in [false, true] {
                for style in [StripReturnStyle.glyph, .text] {
                    let r = row(width, globe: globe, returnStyle: style)
                    #expect(r.cells.first!.x >= 8 - 0.0001, "w=\(width)")
                    #expect(r.cells.last!.maxX <= width - 8 + 0.0001, "w=\(width) globe=\(globe) \(style)")
                    #expect(cell(r, .mic).width == 81, "w=\(width)")
                    #expect(cell(r, .status).width >= 0, "w=\(width)")
                    for slot in [StripSlot.expand, .delete, .returnKey] {
                        #expect(cell(r, slot).width >= StripRow.minKeyWidth - 0.0001, "w=\(width) \(slot)")
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
