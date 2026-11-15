import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutStripRowTests {
    private func row(_ width: Double, globe: Bool = false, returnStyle: StripReturnStyle = .glyph) -> StripRow {
        StripRow.make(width: width, showsGlobe: globe, returnStyle: returnStyle)
    }

    private func cell(_ row: StripRow, _ slot: StripSlot) -> StripCell {
        row.cells.first { $0.slot == slot }!
    }

    private let allCombos: [(globe: Bool, style: StripReturnStyle)] = [(false, .glyph), (false, .text), (true, .glyph), (true, .text)]

    // MARK: order

    @Test func theRowIsChevronMagicMicUndoRedoDeleteReturn() {
        #expect(row(402).cells.map(\.slot) == [.expand, .magic, .mic, .undo, .redo, .delete, .returnKey])
    }

    @Test func theGlobeSitsRightOfTheChevronWhenIOSAsksForIt() {
        #expect(row(402, globe: true).cells.map(\.slot) == [.expand, .globe, .magic, .mic, .undo, .redo, .delete, .returnKey])
    }

    // MARK: sizes

    @Test func onARegularPhoneKeysAreEqualAndTheMicIsWider() {
        let r = row(402)
        // (402 - 2 x 6.33 margin - 6 gaps x 6) / (6 keys + 1.5 mic)
        let key = (402 - 12.66 - 36) / 7.5
        #expect(abs(cell(r, .expand).width - key) < 0.0001)
        #expect(abs(cell(r, .returnKey).width - key) < 0.0001)
        #expect(abs(cell(r, .mic).width - key * StripRow.micWeight) < 0.0001)
        #expect(r.showsUndo && r.showsRedo)
    }

    @Test func aTextReturnLabelGetsAFixedWiderKey() {
        let r = row(402, returnStyle: .text)
        #expect(cell(r, .returnKey).width == StripRow.textReturnWidth)
    }

    // MARK: fitting

    @Test func cellsAreSeparatedByTheGapAndFillTheWidthBetweenTheMargins() {
        for width in [320.0, 375, 402, 430, 874] {
            for combo in allCombos {
                let r = row(width, globe: combo.globe, returnStyle: combo.style)
                #expect(r.cells.first!.x == 6.33)
                #expect(abs(r.cells.last!.maxX - (width - 6.33)) < 0.0001, "w=\(width) \(combo)")
                for (a, b) in zip(r.cells, r.cells.dropFirst()) {
                    #expect(abs(b.x - a.maxX - 6) < 0.0001)
                }
            }
        }
    }

    @Test func redoGoesFirstThenUndoWhenKeysWouldFallBelowTheFloor() {
        // 375 pt with a globe and a text return: redo has to go, undo stays.
        let narrow = row(375, globe: true, returnStyle: .text)
        #expect(narrow.showsUndo && !narrow.showsRedo)
        #expect(narrow.cells.map(\.slot) == [.expand, .globe, .magic, .mic, .undo, .delete, .returnKey])
        // 320 pt with a globe and a text return: both go.
        let se = row(320, globe: true, returnStyle: .text)
        #expect(!se.showsUndo && !se.showsRedo)
        #expect(se.cells.map(\.slot) == [.expand, .globe, .magic, .mic, .delete, .returnKey])
    }

    @Test func redoStaysOnRegularPhones() {
        #expect(row(402).showsRedo)
        #expect(row(402, globe: true).showsRedo)
        #expect(row(430, globe: true, returnStyle: .text).showsRedo)
    }

    @Test func fromTheSmallestPhoneUpEveryKeyKeepsItsFloorAndTheMicIsTheWidest() {
        for width in stride(from: 320.0, through: 932, by: 1) {
            for combo in allCombos {
                let r = row(width, globe: combo.globe, returnStyle: combo.style)
                for c in r.cells where !(c.slot == .returnKey && combo.style == .text) {
                    #expect(c.width >= StripRow.minKeyWidth - 0.0001, "w=\(width) \(combo) \(c.slot)")
                }
                #expect(cell(r, .mic).width >= cell(r, .magic).width, "w=\(width)")
                #expect(r.cells.last!.maxX <= width - 6.33 + 0.0001, "w=\(width) \(combo)")
            }
        }
    }

    @Test func noKeyEverCollapsesToNothingEvenBelowThePhoneSizes() {
        for width in stride(from: 240.0, through: 932, by: 4) {
            for combo in allCombos {
                let r = row(width, globe: combo.globe, returnStyle: combo.style)
                for c in r.cells { #expect(c.width > 0, "w=\(width) \(combo) \(c.slot)") }
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

    @Test func theChevronAndReturnHitAreasReachTheScreenEdges() {
        let r = row(402)
        #expect(cell(r, .expand).hitX == 0)
        #expect(cell(r, .returnKey).hitMaxX == 402)
        #expect(abs(cell(r, .returnKey).trailingInset - 6.33) < 0.0001)
        #expect(cell(r, .expand).leadingInset == 6.33)
    }
}
