import Foundation
import Testing
@testable import LegatoKeyboardCore

/// #300: a chunk's insert enters as a fast character burst, capped in total time, never split inside a grapheme.
@Suite struct ChunkEntranceTests {
    @Test func aShortInsertGoesGraphemeByGrapheme() {
        let plan = ChunkEntrance.plan("hello")
        #expect(plan.pieces == ["h", "e", "l", "l", "o"])
        #expect(plan.gapMs == ChunkEntrance.gapMs)
        #expect(plan.durationMs == 4 * ChunkEntrance.gapMs)
    }

    @Test func graphemeClustersAndCRLFAreNeverSplit() {
        let family = "👨‍👩‍👧‍👦", flag = "🇩🇪", accent = "e\u{301}"
        let plan = ChunkEntrance.plan("a" + family + flag + accent + "\r\n" + "b")
        #expect(plan.pieces == ["a", family, flag, accent, "\r\n", "b"])
        // Grouped pieces (a long insert) stay on cluster borders too.
        let long = String(repeating: family + accent + "\r\n", count: 60)
        let grouped = ChunkEntrance.plan(long)
        #expect(grouped.pieces.joined() == long)
        #expect(grouped.pieces.allSatisfy { Array($0).count == $0.unicodeScalars.count || !$0.isEmpty })
        let clusters = Array(long)
        var index = 0
        for piece in grouped.pieces { #expect(Array(piece) == Array(clusters[index..<(index + Array(piece).count)])); index += Array(piece).count }
    }

    @Test func aBurstThatFallsBehindWritesWhatIsLeftInFewerPiecesAndNeverPastTheCap() {
        let pieces = Array(repeating: "ab", count: 20)
        // On time: the pieces and a gap go on as planned.
        let onTime = ChunkEntrance.fit(pieces, elapsedMs: 0, writeMs: 1, gapMs: 8, capMs: 250)
        #expect(onTime.pieces == pieces && onTime.waitMs == 8)
        // Slow writes (10 ms each): not all 19 more fit in what is left; the text is regrouped, never lost or split in a cluster.
        let slow = ChunkEntrance.fit(pieces, elapsedMs: 40, writeMs: 10, gapMs: 8, capMs: 250)
        #expect(slow.pieces.joined() == pieces.joined() && slow.pieces.count < pieces.count)
        #expect(Double(slow.pieces.count) * 18 <= 250 - 40 + 1e-9)
        // Out of budget: everything left in one piece, at once.
        let out = ChunkEntrance.fit(pieces, elapsedMs: 250, writeMs: 10, gapMs: 8, capMs: 250)
        #expect(out.pieces == [pieces.joined()] && out.waitMs == 0)
        let family = "👨‍👩‍👧‍👦"
        let marks = ChunkEntrance.fit([family, "e", "\u{301}x", family], elapsedMs: 240, writeMs: 5, gapMs: 8, capMs: 250)
        #expect(marks.pieces == [family + "e\u{301}x" + family])
    }

    @Test func theBurstNeverExceedsTheCap() {
        for count in [1, 2, 31, 32, 33, 40, 62, 63, 64, 100, 500, 5_000] {
            let text = String(repeating: "x", count: count)
            let plan = ChunkEntrance.plan(text)
            #expect(plan.pieces.joined() == text, "\(count)")
            #expect(plan.durationMs <= ChunkEntrance.capMs + 1e-9, "\(count): \(plan.durationMs)")
            #expect(plan.gapMs <= ChunkEntrance.gapMs && (plan.pieces.count < 2 || plan.gapMs >= ChunkEntrance.minGapMs - 1e-9), "\(count)")
        }
        // One piece per 60 Hz frame, never faster: what fits the cap goes grapheme by grapheme, more groups.
        #expect(ChunkEntrance.plan(String(repeating: "x", count: 12)) == .init(pieces: Array(repeating: "x", count: 12), gapMs: 1000.0 / 60))
        #expect(ChunkEntrance.plan(String(repeating: "x", count: 40)).pieces.count < 40)
        #expect(ChunkEntrance.plan(String(repeating: "x", count: 40)).gapMs == 1000.0 / 60)
        #expect(ChunkEntrance.plan(String(repeating: "x", count: 500)).pieces.count < 500)
    }

    @Test func disabledOrTrivialIsOnePiece() {
        #expect(ChunkEntrance.plan("hello", enabled: false) == .init(pieces: ["hello"], gapMs: 0))
        #expect(ChunkEntrance.plan("h") == .init(pieces: ["h"], gapMs: 0))
        #expect(ChunkEntrance.plan("").pieces.isEmpty)
    }
}
