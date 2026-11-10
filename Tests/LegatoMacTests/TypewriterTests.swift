import Foundation
import Testing
@testable import LegatoMac

@MainActor @Suite struct TypewriterTests {
    @Test func stepsAreIndividualGraphemesAndJoinBackExactly() {
        let text = "Hallo  Welt, wie geht's?\nNeue Zeile 😀 fertig."
        let steps = TypewriterPlan.steps(text)
        #expect(steps.joined() == text)
        #expect(steps.first == "H" && steps.count == text.count && steps.allSatisfy { $0.count == 1 })
        #expect(TypewriterPlan.steps("").isEmpty)
    }

    @Test func longTextsKeepIndividualCharacterSteps() {
        let text = (1...450).map { "w\($0)" }.joined(separator: " ")
        let steps = TypewriterPlan.steps(text)
        #expect(steps.count == text.count && steps.joined() == text)
    }

    @Test func longTakesKeepAVisiblePauseBetweenCharacters() {
        for count in [2, 3, 5] {
            let total = TypewriterPlan.interval(steps: count) * (count - 1)
            #expect(total <= TypewriterPlan.duration && TypewriterPlan.duration - total < .microseconds(1))
        }
        #expect(TypewriterPlan.interval(steps: 3) == .milliseconds(150))
        let long = TypewriterPlan.steps((1...450).map { "w\($0)" }.joined(separator: " "))
        #expect(TypewriterPlan.interval(steps: long.count) == .milliseconds(20))
        #expect(TypewriterPlan.interval(steps: 1) == .zero && TypewriterPlan.interval(steps: 0) == .zero)
    }

    @Test func slowWritesShortenTheFollowingPauses() async {
        let clock = ContinuousClock()
        var pauses: [Duration] = []
        _ = await Typewriter.run("eins zwei drei", sleep: { pauses.append($0) }, clock: clock) { _ in
            let until = clock.now + .milliseconds(200)
            while clock.now < until {} // a field that takes 200 ms per write
            return true
        }
        #expect(pauses.count == 0, "Behind schedule: no pauses, writes go back to back")
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
        #expect(written == "eins zwei drei".map(String.init) && pauses.count == written.count - 1)
    }

    @Test func runStopsAtTheFirstFailedStepAndReturnsTheRest() async {
        var count = 0
        let result = await Typewriter.run("eins zwei drei vier", sleep: { _ in }) { _ in count += 1; return count < 3 }
        #expect(result == .init(remainder: "ns zwei drei vier", wroteAny: true))
        let none = await Typewriter.run("eins zwei", sleep: { _ in }) { _ in false }
        #expect(none == .init(remainder: "eins zwei", wroteAny: false))
    }

    @Test func legatoEventsAreRecognisedByTheirTag() {
        #expect(SyntheticEvent.isLegato(SyntheticEvent.userData))
        #expect(!SyntheticEvent.isLegato(0) && !SyntheticEvent.isLegato(SyntheticEvent.userData + 1))
    }
    @Test func asynchronousControlWritesRemainIndividualAndKeepTheirExactRemainder() async {
        var steps: [String] = []
        var controls: [String] = []
        let result = await Typewriter.run("a\nb\tc", sleep: { _ in }, writeAsync: { step in
            await Task.yield()
            if TypewriterPlan.needsPaste(step) { controls.append(step) }
            if step == "b" { return false }
            steps.append(step)
            return true
        })
        #expect(steps == ["a", "\n"])
        #expect(controls == ["\n"])
        #expect(result == .init(remainder: "b\tc", wroteAny: true))
    }

}
