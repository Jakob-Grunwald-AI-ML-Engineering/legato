import Foundation
import Testing
@testable import LegatoCore

@Suite struct LiveTranscriptTests {
    // MARK: tail

    @Test func shortTextIsReturnedUnchanged() {
        let text = "hello world"
        #expect(LiveTranscript.tail(of: text) == "hello world")
    }

    @Test func tailTrimsSurroundingWhitespace() {
        let text = " hello "
        #expect(LiveTranscript.tail(of: text) == "hello")
    }

    @Test func characterLimitCutsAtWordBoundaryWithEllipsis() {
        let text = "the quick brown fox jumps over"
        // The last 13 characters would be "ox jumps over": "ox" is half a word, so it goes.
        #expect(LiveTranscript.tail(of: text, maxCharacters: 14, maxBytes: 1024) == "…jumps over")
    }

    @Test func characterLimitKeepsAWholeWordThatFitsExactly() {
        let text = "the quick brown fox jumps over"
        #expect(LiveTranscript.tail(of: text, maxCharacters: 15, maxBytes: 1024) == "…fox jumps over")
    }

    @Test func resultNeverExceedsTheCharacterLimit() {
        let text = String(repeating: "word ", count: 100)
        let tail = LiveTranscript.tail(of: text, maxCharacters: 120, maxBytes: 1024)
        #expect(tail.count <= 120)
        #expect(tail.hasPrefix("…"))
        #expect(tail.hasSuffix("word"))
    }

    @Test func aSingleOverlongWordIsCutHardWithEllipsis() {
        let text = String(repeating: "a", count: 50)
        #expect(LiveTranscript.tail(of: text, maxCharacters: 10, maxBytes: 1024) == "…" + String(repeating: "a", count: 9))
    }

    @Test func byteLimitCountsEmojiAsMultipleBytes() {
        let text = String(repeating: "😀 ", count: 100) // 4 bytes + space each
        let tail = LiveTranscript.tail(of: text, maxCharacters: 120, maxBytes: 40)
        #expect(tail.utf8.count <= 40)
        #expect(tail.hasPrefix("…"))
        #expect(tail.dropFirst().allSatisfy { $0 == "😀" || $0 == " " })
        #expect(tail.hasSuffix("😀"))
    }

    @Test func cutNeverSplitsAGraphemeCluster() {
        let accented = "e\u{301}" // two scalars, one Character
        let text = String(repeating: accented, count: 100)
        let tail = LiveTranscript.tail(of: text, maxCharacters: 120, maxBytes: 20) // 17 bytes of text after the ellipsis
        #expect(tail.utf8.count <= 20)
        let body = tail.dropFirst()
        #expect(!body.isEmpty)
        #expect(body.allSatisfy { $0 == Character(accented) })
        #expect(body.unicodeScalars.count == body.count * 2) // no lone combining mark
    }

    @Test func familyEmojiClusterStaysWholeOrIsDropped() {
        let family = "👨‍👩‍👧‍👦" // 25 bytes, one Character
        let text = "hi " + String(repeating: family, count: 3)
        let tail = LiveTranscript.tail(of: text, maxCharacters: 120, maxBytes: 60) // fits 2 clusters (50) after the ellipsis (3)
        #expect(tail.utf8.count <= 60)
        #expect(tail.dropFirst().allSatisfy { $0 == Character(family) })
        #expect(tail.dropFirst().count == 2)
    }

}
