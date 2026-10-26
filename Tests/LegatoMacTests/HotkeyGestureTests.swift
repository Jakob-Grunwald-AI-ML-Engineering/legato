import Testing
@testable import LegatoMac

/// A press is held back for `armDelay` (0.2 s) before it may start a run, so a chord such as
/// Right ⌘+C never starts dictation: nothing starts until the trigger has been down alone that long.
@Suite struct HotkeyGestureTests {
    @Test func defaultsToHybridWithThresholds() {
        let g = HotkeyGesture()
        #expect(g.mode == .hybrid)
        #expect(g.tapThreshold == 0.35)
        #expect(g.armDelay == 0.2)
    }

    // MARK: arming

    @Test func pressDoesNotStartImmediately() {
        for mode in HotkeyGesture.Mode.allCases {
            var g = HotkeyGesture(mode: mode)
            #expect(g.pressed(at: 0) == nil)
        }
    }

    @Test func pressedTriggerExposesTheArmDeadline() {
        var g = HotkeyGesture(armDelay: 0.25)
        #expect(g.armDeadline == nil)
        _ = g.pressed(at: 10)
        #expect(g.armDeadline == 10.25)
        #expect(g.isTriggerDown)
    }

    @Test func tickBeforeTheDelayDoesNothing() {
        var g = HotkeyGesture(armDelay: 0.25)
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.2) == nil)
        #expect(g.armDeadline == 0.25)
    }

    @Test func tickAtTheDelayStartsOnceAndClearsTheDeadline() {
        var g = HotkeyGesture(armDelay: 0.25)
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.25) == .start)
        #expect(g.armDeadline == nil)
        #expect(g.tick(at: 1) == nil)
    }

    @Test func tickWithoutPressDoesNothing() {
        var g = HotkeyGesture()
        #expect(g.tick(at: 5) == nil)
        #expect(g.armDeadline == nil)
    }

    // MARK: hybrid

    @Test func shortTapStartsOnReleaseAndLatches() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == nil)
        #expect(g.released(at: 0.1) == .start)
        // The run is latched on: the next tap stops it (on release, so a chord can still spoil the stop).
        #expect(g.pressed(at: 5) == nil)
        #expect(g.released(at: 5.1) == .stop)
    }

    @Test func holdStartsAtTheArmDelayAndStopsOnRelease() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.2) == .start)
        #expect(g.released(at: 12) == .stop)
        // The next press starts a fresh run.
        #expect(g.pressed(at: 13) == nil)
        #expect(g.tick(at: 13.2) == .start)
    }

    @Test func releaseAfterArmingButBeforeTheTapThresholdLatches() {
        var g = HotkeyGesture(tapThreshold: 0.5, armDelay: 0.25)
        _ = g.pressed(at: 1)
        #expect(g.tick(at: 1.25) == .start)
        #expect(g.released(at: 1.375) == nil) // 0.375 < 0.5: a tap, latched
        #expect(g.pressed(at: 4) == nil)
        #expect(g.released(at: 4.1) == .stop)
    }

    @Test func holdAtTheTapThresholdIsPushToTalk() {
        // Binary-exact times: exactly the threshold counts as a hold.
        var g = HotkeyGesture(tapThreshold: 0.5, armDelay: 0.25)
        _ = g.pressed(at: 1)
        #expect(g.tick(at: 1.25) == .start)
        #expect(g.released(at: 1.5) == .stop)
    }

    @Test func tapJustUnderTheArmDelayStartsOnRelease() {
        var g = HotkeyGesture(armDelay: 0.25)
        _ = g.pressed(at: 10)
        #expect(g.released(at: 10.2) == .start)
    }

    // MARK: repeats and strays

    @Test func repeatPressesAreIgnored() {
        var g = HotkeyGesture(armDelay: 0.25)
        #expect(g.pressed(at: 0) == nil)
        #expect(g.pressed(at: 0.0625) == nil)
        #expect(g.pressed(at: 0.125) == nil)
        // Repeats do not reset the arm clock.
        #expect(g.armDeadline == 0.25)
        #expect(g.released(at: 0.1875) == .start)
    }

    @Test func releaseWithoutPressIsIgnored() {
        var g = HotkeyGesture()
        #expect(g.released(at: 1) == nil)
        #expect(g.pressed(at: 2) == nil)
        #expect(g.tick(at: 2.2) == .start)
    }

    @Test func lateTimerStillTreatsAShortHeldTapAsAStartingTap() {
        // The arm timer had not fired yet when the release arrived (0.3 s < tap threshold).
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        #expect(g.released(at: 0.3) == .start)
    }

    @Test func lateTimerDoesNotStartALongPressThatAlreadyEnded() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        #expect(g.released(at: 2) == nil) // no run to stop, none worth starting
        #expect(g.pressed(at: 3) == nil)
        #expect(g.tick(at: 3.2) == .start)
    }

    // MARK: chord

    @Test func chordBeforeArmingNeverStartsAndNeverCancels() {
        var g = HotkeyGesture()
        #expect(g.pressed(at: 0) == nil)
        #expect(g.otherKeyDown() == nil) // Right ⌘+C
        #expect(g.armDeadline == nil)
        #expect(g.tick(at: 0.5) == nil)
        #expect(g.released(at: 0.6) == nil)
        // A later press is a fresh gesture.
        #expect(g.pressed(at: 3) == nil)
        #expect(g.tick(at: 3.2) == .start)
    }

    @Test func chordBeforeArmingNeverStartsInAnyMode() {
        for mode in HotkeyGesture.Mode.allCases {
            var g = HotkeyGesture(mode: mode)
            _ = g.pressed(at: 0)
            #expect(g.otherKeyDown() == nil)
            #expect(g.tick(at: 1) == nil)
            #expect(g.released(at: 1.1) == nil)
        }
    }

    @Test func chordAfterArmingCancelsTheStartedRun() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.2) == .start)
        #expect(g.otherKeyDown() == .cancel)
        // The release of the chorded press does nothing, and a later press starts afresh.
        #expect(g.released(at: 5) == nil)
        #expect(g.pressed(at: 6) == nil)
        #expect(g.tick(at: 6.2) == .start)
    }

    @Test func secondOtherKeyAfterCancelIsIgnored() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.tick(at: 0.2)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.otherKeyDown() == nil)
    }

    @Test func otherKeyWhileTriggerUpIsIgnored() {
        var g = HotkeyGesture()
        #expect(g.otherKeyDown() == nil)
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // started and latched
        #expect(g.otherKeyDown() == nil)
        // The latched run is untouched: the next tap still stops it.
        #expect(g.pressed(at: 4) == nil)
        #expect(g.released(at: 4.1) == .stop)
    }

    @Test func chordDuringStopTapKeepsTheRunning() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // started and latched
        #expect(g.pressed(at: 5) == nil)
        #expect(g.otherKeyDown() == nil) // e.g. Right Cmd+C while dictating
        #expect(g.released(at: 5.1) == nil)
        // Still latched: a clean tap stops it.
        #expect(g.pressed(at: 9) == nil)
        #expect(g.released(at: 9.1) == .stop)
    }

    @Test func tickDuringAStopTapDoesNothing() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1)
        _ = g.pressed(at: 5)
        #expect(g.armDeadline == nil)
        #expect(g.tick(at: 6) == nil)
    }

    // MARK: runEnded and reset

    @Test func runEndedUnlatches() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // started and latched
        g.runEnded() // e.g. the engine aborted
        #expect(g.pressed(at: 4) == nil)
        #expect(g.tick(at: 4.2) == .start)
    }

    @Test func runEndedWhileHeldMakesTheReleaseInert() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.tick(at: 0.2)
        g.runEnded()
        #expect(g.released(at: 5) == nil)
        #expect(g.pressed(at: 6) == nil)
        #expect(g.tick(at: 6.2) == .start)
    }

    @Test func runEndedWhenIdleChangesNothing() {
        var g = HotkeyGesture()
        g.runEnded()
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.2) == .start)
    }

    @Test func resetDropsAPressInProgress() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.tick(at: 0.2)
        g.reset() // the event tap was restarted: the release will never arrive
        #expect(!g.isTriggerDown)
        #expect(g.armDeadline == nil)
        #expect(g.released(at: 3) == nil)
        #expect(g.pressed(at: 4) == nil)
        #expect(g.tick(at: 4.2) == .start)
    }

    @Test func resetDropsALatch() {
        var g = HotkeyGesture()
        _ = g.pressed(at: 0)
        _ = g.released(at: 0.1) // latched
        g.reset()
        #expect(g.pressed(at: 5) == nil)
        #expect(g.tick(at: 5.2) == .start) // a fresh start, not a stop tap
    }

    @Test func isTriggerDownTracksThePress() {
        var g = HotkeyGesture()
        #expect(!g.isTriggerDown)
        _ = g.pressed(at: 0)
        #expect(g.isTriggerDown)
        _ = g.released(at: 0.1) // latched, trigger up
        #expect(!g.isTriggerDown)
        _ = g.pressed(at: 3) // stopping tap
        #expect(g.isTriggerDown)
        _ = g.released(at: 3.1)
        #expect(!g.isTriggerDown)
    }

    // MARK: toggle

    @Test func toggleStartsAtTheArmDelayAndStopsOnNextTapRegardlessOfDuration() {
        var g = HotkeyGesture(mode: .toggle)
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.2) == .start)
        #expect(g.released(at: 30) == nil) // a long first press does not turn into push-to-talk
        #expect(g.pressed(at: 40) == nil)
        #expect(g.released(at: 40.05) == .stop)
        #expect(g.pressed(at: 50) == nil)
        #expect(g.tick(at: 50.2) == .start)
    }

    @Test func toggleShortTapStartsOnRelease() {
        var g = HotkeyGesture(mode: .toggle)
        _ = g.pressed(at: 0)
        #expect(g.released(at: 0.1) == .start)
        _ = g.pressed(at: 4)
        #expect(g.released(at: 4.1) == .stop)
    }

    @Test func toggleChordAfterArmingCancels() {
        var g = HotkeyGesture(mode: .toggle)
        _ = g.pressed(at: 0)
        _ = g.tick(at: 0.2)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.released(at: 1) == nil)
    }

    // MARK: hold

    @Test func holdModeStartsAtTheArmDelayAndStopsOnRelease() {
        var g = HotkeyGesture(mode: .hold)
        _ = g.pressed(at: 0)
        #expect(g.tick(at: 0.2) == .start)
        #expect(g.released(at: 0.3) == .stop)
    }

    @Test func holdTapShorterThanTheArmDelayDoesNothing() {
        var g = HotkeyGesture(mode: .hold)
        #expect(g.pressed(at: 0) == nil)
        #expect(g.released(at: 0.05) == nil)
        #expect(g.tick(at: 0.5) == nil)
        #expect(g.pressed(at: 1) == nil)
    }

    @Test func holdChordAfterArmingCancels() {
        var g = HotkeyGesture(mode: .hold)
        _ = g.pressed(at: 0)
        _ = g.tick(at: 0.2)
        #expect(g.otherKeyDown() == .cancel)
        #expect(g.released(at: 2) == nil)
    }
}
