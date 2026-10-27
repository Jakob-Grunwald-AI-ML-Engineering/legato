import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutGlyphMorphTests {
    private func ids(_ glyphs: [GlyphMorph.Glyph]) -> [Int] { glyphs.map(\.id) }
    private func chars(_ glyphs: [GlyphMorph.Glyph]) -> String { String(glyphs.map(\.character)) }

    @Test func aFreshMorphHoldsTheTextAsGlyphsWithConsecutiveIds() {
        let morph = GlyphMorph(text: "hey")
        #expect(morph.text == "hey")
        #expect(ids(morph.glyphs) == [0, 1, 2])
        #expect(morph.removals.isEmpty)
        #expect(morph.insertionStagger.isEmpty)
    }

    @Test func identicalTextKeepsEveryIdAndMovesNothing() {
        let next = GlyphMorph(text: "hello").morphing(to: "hello")
        #expect(ids(next.glyphs) == [0, 1, 2, 3, 4])
        #expect(next.removals.isEmpty)
        #expect(next.insertionStagger.isEmpty)
    }

    @Test func helloToHelpKeepsHELAndRemovesOThenLRightToLeftAndInsertsP() {
        let next = GlyphMorph(text: "hello").morphing(to: "help")
        #expect(chars(next.glyphs) == "help")
        #expect(ids(next.glyphs) == [0, 1, 2, 5])
        #expect(next.removals.map(\.glyph.id) == [4, 3])
        #expect(next.removals.map(\.glyph.character) == ["o", "l"])
        #expect(next.removals.map(\.stagger) == [0, 1])
        #expect(next.insertionStagger == [5: 0])
    }

    @Test func textWithNoOverlapRemovesEverythingAndInsertsEverything() {
        let next = GlyphMorph(text: "there").morphing(to: "my")
        #expect(chars(next.glyphs) == "my")
        #expect(ids(next.glyphs) == [5, 6])
        #expect(next.removals.map(\.glyph.character) == ["e", "r", "e", "h", "t"])
        #expect(next.removals.map(\.stagger) == [0, 1, 2, 3, 4])
        #expect(next.insertionStagger == [5: 1, 6: 0])
    }

    @Test func emptyToWordInsertsEveryGlyphRightmostFirst() {
        let next = GlyphMorph(text: "").morphing(to: "abc")
        #expect(ids(next.glyphs) == [0, 1, 2])
        #expect(next.removals.isEmpty)
        #expect(next.insertionStagger == [0: 2, 1: 1, 2: 0])
    }

    @Test func wordToEmptyRemovesEveryGlyphRightToLeft() {
        let next = GlyphMorph(text: "abc").morphing(to: "")
        #expect(next.glyphs.isEmpty)
        #expect(next.text == "")
        #expect(next.removals.map(\.glyph.character) == ["c", "b", "a"])
        #expect(next.removals.map(\.stagger) == [0, 1, 2])
        #expect(next.insertionStagger.isEmpty)
    }

    @Test func insertionsInTheMiddleStaggerFromTheRight() {
        let next = GlyphMorph(text: "hlo").morphing(to: "hello")
        // h, l, o keep their ids (the earlier of two equal matches wins); e and the second l are new.
        #expect(chars(next.glyphs) == "hello")
        #expect(ids(next.glyphs) == [0, 3, 1, 4, 2])
        #expect(next.removals.isEmpty)
        #expect(next.insertionStagger == [3: 1, 4: 0])
    }

    @Test func keptGlyphsKeepTheirIdsWhenTheyShiftRight() {
        let next = GlyphMorph(text: "ello").morphing(to: "hello")
        #expect(ids(next.glyphs) == [4, 0, 1, 2, 3])
        #expect(next.insertionStagger == [4: 0])
    }

    @Test func repeatedLettersKeepStableIdsAcrossChainedUpdates() {
        let a = GlyphMorph(text: "hello")           // h0 e1 l2 l3 o4
        let b = a.morphing(to: "help")               // h0 e1 l2 p5
        let c = b.morphing(to: "hell")               // h0 e1 l2 l6; p5 removed
        #expect(ids(b.glyphs) == [0, 1, 2, 5])
        #expect(ids(c.glyphs) == [0, 1, 2, 6])
        #expect(c.removals.map(\.glyph.id) == [5])
        #expect(c.insertionStagger == [6: 0])
        let d = c.morphing(to: "helll")               // the third l is new, the old three keep their ids
        #expect(ids(d.glyphs) == [0, 1, 2, 6, 7])
        #expect(d.insertionStagger == [7: 0])
    }

    @Test func aRemovedIdIsNeverReusedByALaterInsertion() {
        let a = GlyphMorph(text: "ab")
        let b = a.morphing(to: "a")
        let c = b.morphing(to: "ab")
        #expect(ids(c.glyphs) == [0, 2])
        #expect(b.removals.map(\.glyph.id) == [1])
    }

    @Test func eachUpdateReportsOnlyItsOwnChanges() {
        let b = GlyphMorph(text: "hello").morphing(to: "help")
        let c = b.morphing(to: "help")
        #expect(c.removals.isEmpty)
        #expect(c.insertionStagger.isEmpty)
    }

    @Test func graphemeClustersAreSingleGlyphs() {
        let family = "👨‍👩‍👧"
        let morph = GlyphMorph(text: "a\(family)b")
        #expect(morph.glyphs.count == 3)
        let next = morph.morphing(to: "\(family)b!")
        #expect(next.glyphs.map(\.character) == [Character(family), "b", "!"])
        #expect(ids(next.glyphs) == [1, 2, 3])
        #expect(next.removals.map(\.glyph.id) == [0])
    }

    @Test func aDecomposedUmlautIsOneGlyphAndMatchesItsPrecomposedForm() {
        let decomposed = "u\u{0308}ber"
        let morph = GlyphMorph(text: decomposed)
        #expect(morph.glyphs.count == 4)
        let next = morph.morphing(to: "\u{00FC}bers")
        #expect(ids(next.glyphs) == [0, 1, 2, 3, 4])
        #expect(next.removals.isEmpty)
        #expect(next.insertionStagger == [4: 0])
    }
}
