import Testing
@testable import LegatoKeyboardCore

@Suite struct TypewriterDrainTests {
    @Test func revealsTheShareOfThePendingTextThatFitsTheFrame() {
        // 100 pending over a 250 ms window: a 25 ms frame is a tenth of it.
        #expect(TypewriterDrain.step(revealed: 0, target: 100, dtMs: 25) == 10)
    }

    @Test func roundsTheShareUp() {
        #expect(TypewriterDrain.step(revealed: 0, target: 100, dtMs: 16) == 7) // 6.4
    }

    @Test func alwaysRevealsAtLeastOneCharacter() {
        #expect(TypewriterDrain.step(revealed: 99, target: 100, dtMs: 1) == 100)
        #expect(TypewriterDrain.step(revealed: 10, target: 100, dtMs: 0) == 11)
    }

    @Test func neverOvershootsTheTarget() {
        #expect(TypewriterDrain.step(revealed: 90, target: 100, dtMs: 10_000) == 100)
    }

    @Test func aRevealedTargetStaysPut() {
        #expect(TypewriterDrain.step(revealed: 100, target: 100, dtMs: 33) == 100)
        #expect(TypewriterDrain.step(revealed: 120, target: 100, dtMs: 33) == 100) // the target shrank
    }

    @Test func catchesUpExponentiallyNeverFarBehind() {
        var revealed = 0
        var frames = 0
        while revealed < 1_000, frames < 1_000 {
            revealed = TypewriterDrain.step(revealed: revealed, target: 1_000, dtMs: 33)
            frames += 1
        }
        #expect(revealed == 1_000)
        #expect(frames < 60) // under two seconds at 30 Hz
    }

    @Test func onlyAForwardGrowthIsAPrefixGrowth() {
        #expect(TypewriterDrain.isPrefixGrowth(prev: "hello", next: "hello world"))
        #expect(TypewriterDrain.isPrefixGrowth(prev: "hello", next: "hello"))
        #expect(TypewriterDrain.isPrefixGrowth(prev: "", next: "hello"))
        #expect(!TypewriterDrain.isPrefixGrowth(prev: "hello", next: "hallo world"))
        #expect(!TypewriterDrain.isPrefixGrowth(prev: "hello world", next: "hello"))
    }
}
