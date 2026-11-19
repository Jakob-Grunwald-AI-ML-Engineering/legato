import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutTopRowLayoutTests {
    // iPhone 17 portrait (`KeyboardMetrics`): margin 6.33, gap 6, emoji key 43.33, return key 93.
    private func layout(_ mode: KeyboardMode, _ side: DictationKeySide = .right, width: Double = 402, globe: Bool = false,
                        returnStyle: TopRowReturnStyle = .glyph, landscape: Bool = false, scale: Double = 1) -> TopRowLayout {
        TopRowLayout.make(mode: mode, side: side, width: width, landscape: landscape, margin: 6.33, gap: 6,
                          keyWidth: 43.33, columnWidth: 93, showsGlobe: globe, returnStyle: returnStyle, scale: scale)
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    private func contains(_ outer: KeyRect, _ inner: KeyRect) -> Bool {
        outer.x <= inner.x + 0.0001 && outer.maxX >= inner.maxX - 0.0001 && outer.y <= inner.y + 0.0001 && outer.maxY >= inner.maxY - 0.0001
    }

    // MARK: full

    @Test func theFullRowIsTheDictationKeyBesideTheTranscript() {
        let full = layout(.full)
        #expect(full.cells.map(\.slot) == [.dictation])
        let key = full.cell(.dictation)!.face
        // As wide as the native return key, a grid key tall, one pitch above the grid, flush with the grid's right margin.
        #expect(close(key.width, 93) && key.height == 43 && key.y == 13)
        #expect(close(key.maxX, 402 - 6.33))
        // The transcript: the rest of the width, from the screen edge to half a gap off the key, as tall as the key.
        #expect(full.transcript.x == 0 && close(full.transcript.maxX, key.x - 3))
        #expect(full.transcript.y == key.y && full.transcript.height == key.height)
    }

    @Test func theFullKeysTouchAreaReachesTheEdgeTheTopAndTheGrid() {
        let hit = layout(.full).cell(.dictation)!.hit
        #expect(hit.y == 0 && hit.maxY == 67 - 6)
        #expect(close(hit.maxX, 402) && close(hit.x, layout(.full).transcript.maxX))
        #expect(contains(hit, layout(.full).cell(.dictation)!.face))
    }

    @Test func landscapeKeepsTheTranscriptTallEnoughForTwoLines() {
        let full = layout(.full, width: 724, landscape: true)
        let key = full.cell(.dictation)!.face
        #expect(close(key.height, 27.33))
        #expect(full.transcript.height == WordRowHeight.minimumRow)
        #expect(close(full.transcript.y + full.transcript.height / 2, key.y + key.height / 2), "centred on the key")
    }

    // MARK: minimised

    @Test func minimisedHasDeleteAndReturnUnderTheDictationKey() {
        let mini = layout(.minimised)
        #expect(mini.cells.map(\.slot) == [.dictation, .delete, .returnKey])
        let key = mini.cell(.dictation)!.face, delete = mini.cell(.delete)!.face, ret = mini.cell(.returnKey)!.face
        #expect(delete.y == key.y + 54 && delete.height == 43)
        // Two keys share the column: (93 - 6) / 2 each, return at the outer edge.
        #expect(close(delete.width, 43.5) && close(ret.width, 43.5))
        #expect(close(delete.x, key.x) && close(ret.maxX, key.maxX) && close(ret.x - delete.maxX, 6))
        // The transcript spans both rows.
        #expect(mini.transcript.y == key.y && mini.transcript.maxY == delete.maxY)
        #expect(close(mini.transcript.maxX, key.x - 3))
    }

    @Test func theGlobeKeySitsInnermostAndWidensTheColumn() {
        let mini = layout(.minimised, globe: true)
        #expect(mini.cells.map(\.slot) == [.dictation, .globe, .delete, .returnKey])
        let key = mini.cell(.dictation)!.face
        #expect(close(key.width, 3 * 43.33 + 2 * 6))
        #expect(close(mini.cell(.globe)!.face.x, key.x) && close(mini.cell(.returnKey)!.face.maxX, key.maxX))
    }

    @Test func aWordedReturnGetsItsWidth() {
        let mini = layout(.minimised, returnStyle: .text)
        #expect(close(mini.cell(.returnKey)!.face.width, TopRowLayout.textReturnWidth))
        #expect(close(mini.cell(.dictation)!.face.width, 43.33 + 6 + 60))
    }

    @Test func minimisedTouchAreasTileTheKeyColumn() {
        for globe in [false, true] {
            for side in DictationKeySide.allCases {
                let mini = layout(.minimised, side, globe: globe)
                let lower = Array(mini.cells.dropFirst())
                let between = 13 + 43 + 5.5
                #expect(close(mini.cell(.dictation)!.hit.maxY, between))
                for (a, b) in zip(lower, lower.dropFirst()) { #expect(close(a.hit.maxX, b.hit.x)) }
                for cell in mini.cells { #expect(contains(cell.hit, cell.face), "\(side) \(cell.slot)") }
                for cell in lower { #expect(close(cell.hit.y, between) && close(cell.hit.maxY, 113)) }
                let edge = side == .right ? lower.last!.hit.maxX : lower.first!.hit.x
                #expect(close(edge, side == .right ? 402 : 0))
            }
        }
    }

    // MARK: mirroring

    @Test func theLeftSideMirrorsTheRightInBothModes() {
        for mode in [KeyboardMode.full, .minimised] {
            for globe in [false, true] {
                let right = layout(mode, .right, globe: globe), left = layout(mode, .left, globe: globe)
                #expect(left.cells.map(\.slot) == [.dictation] + right.cells.dropFirst().map(\.slot).reversed())
                for cell in right.cells {
                    let mirror = left.cell(cell.slot)!
                    #expect(close(mirror.face.x, 402 - cell.face.maxX) && mirror.face.y == cell.face.y, "\(mode) \(cell.slot)")
                    #expect(close(mirror.hit.x, 402 - cell.hit.maxX) && close(mirror.hit.width, cell.hit.width))
                }
                #expect(close(left.transcript.x, 402 - right.transcript.maxX) && close(left.transcript.width, right.transcript.width))
            }
        }
        #expect(close(layout(.full, .left).cell(.dictation)!.face.x, 6.33))
    }

    @Test func theDefaultSideIsRight() {
        #expect(DictationKeySide.standard == .right)
    }

    @Test func aShorterGrantScalesTheRowsDown() {
        let scaled = layout(.minimised, scale: 0.5)
        #expect(scaled.cell(.dictation)!.face.y == 6.5 && scaled.cell(.dictation)!.face.height == 21.5)
        #expect(close(scaled.cell(.returnKey)!.hit.maxY, 56.5))
    }
}
