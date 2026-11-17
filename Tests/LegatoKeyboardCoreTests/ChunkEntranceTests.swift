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

    @Test func theBurstNeverExceedsTheCap() {
        for count in [1, 2, 31, 32, 33, 40, 62, 63, 64, 100, 500, 5_000] {
            let text = String(repeating: "x", count: count)
            let plan = ChunkEntrance.plan(text)
            #expect(plan.pieces.joined() == text, "\(count)")
            #expect(plan.durationMs <= ChunkEntrance.capMs + 1e-9, "\(count): \(plan.durationMs)")
            #expect(plan.gapMs <= ChunkEntrance.gapMs && (plan.pieces.count < 2 || plan.gapMs >= ChunkEntrance.minGapMs - 1e-9), "\(count)")
        }
        // The gap shrinks before graphemes group: 40 graphemes are still 40 pieces.
        #expect(ChunkEntrance.plan(String(repeating: "x", count: 40)).pieces.count == 40)
        #expect(ChunkEntrance.plan(String(repeating: "x", count: 500)).pieces.count < 500)
    }

    @Test func disabledOrTrivialIsOnePiece() {
        #expect(ChunkEntrance.plan("hello", enabled: false) == .init(pieces: ["hello"], gapMs: 0))
        #expect(ChunkEntrance.plan("h") == .init(pieces: ["h"], gapMs: 0))
        #expect(ChunkEntrance.plan("").pieces.isEmpty)
    }
}
