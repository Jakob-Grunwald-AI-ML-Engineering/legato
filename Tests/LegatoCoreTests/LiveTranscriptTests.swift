import Foundation
import Testing
@testable import LegatoCore

@Suite struct LiveTranscriptTests {
    // MARK: edits

    @Test func editsBuildCommittedAndVolatile() {
        var t = LiveTranscript()
        t.apply(.replaceVolatile("hel"))
        #expect(t.committed == "" && t.volatile == "hel" && t.text == "hel")
        t.apply(.replaceVolatile("hello"))
        #expect(t.volatile == "hello")
        t.apply(.replaceVolatile(""))
        t.apply(.commit(delta: "hello"))
        t.apply(.replaceVolatile(" wor"))
        #expect(t.committed == "hello" && t.volatile == " wor" && t.text == "hello wor")
        t.apply(.replaceVolatile(""))
        t.apply(.commit(delta: " world"))
        #expect(t.committed == "hello world" && t.volatile == "" && t.text == "hello world")
    }

    // MARK: tail

    @Test func shortTextIsReturnedUnchanged() {
        var t = LiveTranscript()
        t.apply(.commit(delta: "hello world"))
        #expect(t.tail() == "hello world")
    }

    @Test func tailTrimsSurroundingWhitespace() {
        var t = LiveTranscript()
        t.apply(.commit(delta: " hello "))
        #expect(t.tail() == "hello")
    }

    @Test func tailIncludesVolatileText() {
        var t = LiveTranscript()
        t.apply(.commit(delta: "hello"))
        t.apply(.replaceVolatile(" wor"))
        #expect(t.tail() == "hello wor")
    }

    @Test func characterLimitCutsAtWordBoundaryWithEllipsis() {
        var t = LiveTranscript()
        t.apply(.commit(delta: "the quick brown fox jumps over"))
        // The last 13 characters would be "ox jumps over": "ox" is half a word, so it goes.
        #expect(t.tail(maxCharacters: 14, maxBytes: 1024) == "…jumps over")
    }

    @Test func characterLimitKeepsAWholeWordThatFitsExactly() {
        var t = LiveTranscript()
        t.apply(.commit(delta: "the quick brown fox jumps over"))
        #expect(t.tail(maxCharacters: 15, maxBytes: 1024) == "…fox jumps over")
    }

    @Test func resultNeverExceedsTheCharacterLimit() {
        var t = LiveTranscript()
        t.apply(.commit(delta: String(repeating: "word ", count: 100)))
        let tail = t.tail(maxCharacters: 120, maxBytes: 1024)
        #expect(tail.count <= 120)
        #expect(tail.hasPrefix("…"))
        #expect(tail.hasSuffix("word"))
    }

    @Test func aSingleOverlongWordIsCutHardWithEllipsis() {
        var t = LiveTranscript()
        t.apply(.commit(delta: String(repeating: "a", count: 50)))
        #expect(t.tail(maxCharacters: 10, maxBytes: 1024) == "…" + String(repeating: "a", count: 9))
    }

    @Test func byteLimitCountsEmojiAsMultipleBytes() {
        var t = LiveTranscript()
        t.apply(.commit(delta: String(repeating: "😀 ", count: 100))) // 4 bytes + space each
        let tail = t.tail(maxCharacters: 120, maxBytes: 40)
        #expect(tail.utf8.count <= 40)
        #expect(tail.hasPrefix("…"))
        #expect(tail.dropFirst().allSatisfy { $0 == "😀" || $0 == " " })
        #expect(tail.hasSuffix("😀"))
    }

    @Test func cutNeverSplitsAGraphemeCluster() {
        var t = LiveTranscript()
        let accented = "e\u{301}" // two scalars, one Character
        t.apply(.commit(delta: String(repeating: accented, count: 100)))
        let tail = t.tail(maxCharacters: 120, maxBytes: 20) // 17 bytes of text after the ellipsis
        #expect(tail.utf8.count <= 20)
        let body = tail.dropFirst()
        #expect(!body.isEmpty)
        #expect(body.allSatisfy { $0 == Character(accented) })
        #expect(body.unicodeScalars.count == body.count * 2) // no lone combining mark
    }

    @Test func familyEmojiClusterStaysWholeOrIsDropped() {
        var t = LiveTranscript()
        let family = "👨‍👩‍👧‍👦" // 25 bytes, one Character
        t.apply(.commit(delta: "hi " + String(repeating: family, count: 3)))
        let tail = t.tail(maxCharacters: 120, maxBytes: 60) // fits 2 clusters (50) after the ellipsis (3)
        #expect(tail.utf8.count <= 60)
        #expect(tail.dropFirst().allSatisfy { $0 == Character(family) })
        #expect(tail.dropFirst().count == 2)
    }

    // MARK: throttle

    @Test func publishesAtMostOncePerSecond() {
        var t = LiveTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.apply(.commit(delta: "one"))
        #expect(t.publish(now: t0) == "one")
        t.apply(.commit(delta: " two"))
        #expect(t.publish(now: t0.addingTimeInterval(0.5)) == nil)
        #expect(t.publish(now: t0.addingTimeInterval(0.99)) == nil)
        #expect(t.publish(now: t0.addingTimeInterval(1)) == "one two")
        t.apply(.commit(delta: " three"))
        #expect(t.publish(now: t0.addingTimeInterval(1.5)) == nil)
    }

    @Test func suppressedPublishDoesNotResetTheWindow() {
        var t = LiveTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.apply(.commit(delta: "a"))
        _ = t.publish(now: t0)
        #expect(t.publish(now: t0.addingTimeInterval(0.9)) == nil)
        #expect(t.publish(now: t0.addingTimeInterval(1.0)) != nil)
    }

    @Test func forcedPublishIgnoresTheThrottleAndRestartsTheWindow() {
        var t = LiveTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.apply(.commit(delta: "one"))
        _ = t.publish(now: t0)
        t.apply(.commit(delta: " two"))
        #expect(t.publish(now: t0.addingTimeInterval(0.1), force: true) == "one two")
        #expect(t.publish(now: t0.addingTimeInterval(0.6)) == nil)
    }
}
