import Foundation
import Testing
@testable import LegatoMac

@MainActor @Suite struct TypewriterTests {
    @Test func stepsAreWordsWithTheirTrailingWhitespaceAndJoinBackExactly() {
        let text = "Hallo  Welt, wie geht's?\nNeue Zeile 😀 fertig."
        let steps = TypewriterPlan.steps(text)
        #expect(steps.joined() == text)
        #expect(steps.first == "Hallo  " && steps.count == 8)
        #expect(TypewriterPlan.steps("").isEmpty)
    }

    @Test func longTextsGroupWordsIntoAtMostAHundredSteps() {
        let text = (1...450).map { "w\($0)" }.joined(separator: " ")
        let steps = TypewriterPlan.steps(text)
        #expect(steps.count <= TypewriterPlan.maxSteps && steps.joined() == text)
    }

    @Test func theWholeTakeStaysWithinAboutASecond() {
        #expect(TypewriterPlan.interval(steps: 3) == .milliseconds(25), "Short takes: 25 ms per word")
        #expect(TypewriterPlan.interval(steps: 20) == .milliseconds(25))
        #expect(TypewriterPlan.interval(steps: 100) == .milliseconds(10))
        for count in [1, 5, 40, 41, 80, 100] {
            #expect(TypewriterPlan.interval(steps: count) * max(0, count - 1) <= .seconds(1))
        }
        #expect(TypewriterPlan.interval(steps: 0) == .zero)
    }

    @Test func eventChunksSplitOnGraphemesWithinTwentyUnits() {
        let text = String(repeating: "Größe 😀 👨‍👩‍👧 é ", count: 6)
        let chunks = TypewriterPlan.eventChunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        for chunk in chunks { #expect(chunk.first != nil && !chunk.hasPrefix("\u{200D}") && !chunk.unicodeScalars.first!.properties.isEmojiModifier) }
        // A grapheme is never cut when it fits: the family emoji (8 units) stays whole.
        #expect(chunks.contains { $0.contains("👨‍👩‍👧") })
        #expect(TypewriterPlan.eventChunks("abc", maxUnits: 20) == ["abc"])
    }

    @Test func aGraphemeLongerThanTheLimitIsCutOnScalars() {
        let long = "👩‍👩‍👧‍👦"
        let chunks = TypewriterPlan.eventChunks(long, maxUnits: 6)
        #expect(chunks.joined() == long && chunks.allSatisfy { $0.utf16.count <= 6 })
    }

    @Test func linebreaksAndTabsGoByPaste() {
        #expect(TypewriterPlan.needsPaste("eins\nzwei") && TypewriterPlan.needsPaste("a\tb") && TypewriterPlan.needsPaste("a\r"))
        #expect(!TypewriterPlan.needsPaste("Größe 😀, fertig."))
    }

    @Test func runWritesEveryStepWithPausesBetween() async {
        var written: [String] = []
        var pauses: [Duration] = []
        let result = await Typewriter.run("eins zwei drei", sleep: { pauses.append($0) }) { written.append($0); return true }
        #expect(result == .init(remainder: nil, wroteAny: true))
        #expect(written == ["eins ", "zwei ", "drei"] && pauses == [.milliseconds(25), .milliseconds(25)])
    }

    @Test func runStopsAtTheFirstFailedStepAndReturnsTheRest() async {
        var count = 0
        let result = await Typewriter.run("eins zwei drei vier", sleep: { _ in }) { _ in count += 1; return count < 3 }
        #expect(result == .init(remainder: "drei vier", wroteAny: true))
        let none = await Typewriter.run("eins zwei", sleep: { _ in }) { _ in false }
        #expect(none == .init(remainder: "eins zwei", wroteAny: false))
    }

    @Test func legatoEventsAreRecognisedByTheirTag() {
        #expect(SyntheticEvent.isLegato(SyntheticEvent.userData))
        #expect(!SyntheticEvent.isLegato(0) && !SyntheticEvent.isLegato(SyntheticEvent.userData + 1))
    }
}
