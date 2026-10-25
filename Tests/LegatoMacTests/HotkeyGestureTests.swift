import Testing
@testable import LegatoMac

@Suite struct HotkeyGestureTests {
    @Test func defaultsToHybridWithThreshold() {
        let g = HotkeyGesture()
        #expect(g.mode == .hybrid)
        #expect(g.tapThreshold == 0.35)
    }

    @Test func hybridPressStartsImmediately() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == .start)
    }

    @Test func shortTapLatchesAndNextTapStops() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == .start)
        #expect(g.released(at: 0.2) == nil)
        // The run is latched on: the next tap stops it (on release, so a chord can still cancel the stop).
        #expect(g.pressed(at: 5) == nil)
        #expect(g.released(at: 5.1) == .stop)
    }

    @Test func tapJustUnderThresholdLatches() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 10) == .start)
        #expect(g.released(at: 10.349) == nil)
    }

    @Test func holdAtThresholdIsPushToTalk() {
        // Binary-exact times: exactly the threshold counts as a hold.
        var g = HotkeyGesture(tapThreshold: 0.5)
        #expect(g.pressed(at: 1) == .start)
        #expect(g.released(at: 1.5) == .stop)
    }

    @Test func holdJustOverDefaultThresholdIsPushToTalk() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 10) == .start)
        #expect(g.released(at: 10.36) == .stop)
    }

    @Test func longHoldStopsOnRelease() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == .start)
        #expect(g.released(at: 12) == .stop)
        // The next press starts a fresh run.
        #expect(g.pressed(at: 13) == .start)
    }

    // MARK: repeats

    @Test func repeatPressesAreIgnored() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == .start)
        #expect(g.pressed(at: 0.05) == nil)
        #expect(g.pressed(at: 0.1) == nil)
        // Repeats do not reset the hold clock: still a tap measured from the first press.
        #expect(g.released(at: 0.2) == nil)
    }

    @Test func releaseWithoutPressIsIgnored() {
        var g = HotkeyGesture()
        #expect(g.released(at: 1) == nil)
        #expect(g.pressed(at: 2) == .start)
    }

    // MARK: chord cancel

    @Test func chordWhileHeldCancelsTheStartedRun() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == .start)
        #expect(g.otherKeyDown() == .cancel)
        // The release of the chorded press does nothing, and a later press starts afresh.
        #expect(g.released(at: 0.1) == nil)
        #expect(g.pressed(at: 3) == .start)
    }

    @Test func chordCancelsAHoldInProgress() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == .start)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.released(at: 5) == nil)
    }

    @Test func secondOtherKeyAfterCancelIsIgnored() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.otherKeyDown() == nil)
    }

    @Test func otherKeyWhileTriggerUpIsIgnored() {
        var g = HotkeyGesture()
        #expect(g.otherKeyDown() == nil)
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // latched
        #expect(g.otherKeyDown() == nil)
        // The latched run is untouched: the next tap still stops it.
        #expect(g.pressed(at: 4) == nil)
        #expect(g.released(at: 4.1) == .stop)
    }

    @Test func chordDuringStopTapKeepsTheRunning() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // latched
        #expect(g.pressed(at: 5) == nil)
        #expect(g.otherKeyDown() == nil) // e.g. Right Cmd+C while dictating
        #expect(g.released(at: 5.1) == nil)
        // Still latched: a clean tap stops it.
        #expect(g.pressed(at: 9) == nil)
        #expect(g.released(at: 9.1) == .stop)
    }

    // MARK: runEnded

    @Test func runEndedUnlatches() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // latched
        g.runEnded() // e.g. the engine aborted
        #expect(g.pressed(at: 4) == .start)
    }

    @Test func runEndedWhileHeldMakesTheReleaseInert() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        g.runEnded()
        #expect(g.released(at: 5) == nil)
        #expect(g.pressed(at: 6) == .start)
    }

    @Test func runEndedWhenIdleChangesNothing() {
        var g = HotkeyGesture()
        g.runEnded()
        #expect(g.pressed(at: 0) == .start)
    }

    // MARK: toggle and hold

    @Test func toggleStartsOnPressAndStopsOnNextTapRegardlessOfDuration() {
        var g = HotkeyGesture(mode: .toggle)
        #expect(g.pressed(at: 0) == .start)
        #expect(g.released(at: 30) == nil) // a long first press does not turn into push-to-talk
        #expect(g.pressed(at: 40) == nil)
        #expect(g.released(at: 40.05) == .stop)
        #expect(g.pressed(at: 50) == .start)
    }

    @Test func toggleChordCancels() {
        var g = HotkeyGesture(mode: .toggle)
        #expect(g.pressed(at: 0) == .start)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.released(at: 0.1) == nil)
    }

    @Test func holdStopsOnReleaseEvenWhenShort() {
        var g = HotkeyGesture(mode: .hold)
        #expect(g.pressed(at: 0) == .start)
        #expect(g.released(at: 0.05) == .stop)
        #expect(g.pressed(at: 1) == .start)
    }

    @Test func holdChordCancels() {
        var g = HotkeyGesture(mode: .hold)
        #expect(g.pressed(at: 0) == .start)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.released(at: 2) == nil)
    }
}
