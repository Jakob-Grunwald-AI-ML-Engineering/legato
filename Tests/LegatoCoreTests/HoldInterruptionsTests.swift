import Testing
@testable import LegatoCore

@Suite struct HoldInterruptionsTests {
    private func lost() -> HoldInterruptions {
        var i = HoldInterruptions()
        i.began(wasHolding: true)
        return i
    }

    @Test func endedWhileHoldingTriesToRetakeTheHold() {
        var i = lost()
        let retake = i.ended()
        let rerun = i.finishRetake(.held, generation: i.generation)
        #expect(retake)
        #expect(!rerun)
        #expect(!i.needsResume)
    }

    @Test func aFailedRetakeIsDeferredToTheNextForeground() {
        var i = lost()
        _ = i.ended()
        _ = i.finishRetake(.failed, generation: i.generation)
        #expect(i.shouldResumeWhenForegrounded)
        let again = i.foregrounded()
        _ = i.finishRetake(.held, generation: i.generation)
        #expect(again)
        #expect(!i.shouldResumeWhenForegrounded)
    }

    @Test func notHoldingNeverReactivates() {
        var i = HoldInterruptions()
        i.began(wasHolding: false)
        let retake = i.ended()
        #expect(!retake)
        #expect(!i.shouldResumeWhenForegrounded)
    }

    @Test func aSecondInterruptionKeepsTheLostHold() {
        var i = lost()
        i.began(wasHolding: false) // the lease is already gone
        let retake = i.ended()
        #expect(retake)
    }

    @Test func aRunningDictationCountsAsHoldingOnlyWhenItKeepsTheLease() {
        #expect(HoldInterruptions.wasHolding(leaseHeld: false, dictating: true, keepsLeaseAfterRun: false) == false)
        #expect(HoldInterruptions.wasHolding(leaseHeld: false, dictating: true, keepsLeaseAfterRun: true))
        #expect(HoldInterruptions.wasHolding(leaseHeld: true, dictating: false, keepsLeaseAfterRun: false))
        #expect(HoldInterruptions.wasHolding(leaseHeld: false, dictating: false, keepsLeaseAfterRun: true) == false)
    }

    // 1. A lease published mid-interruption (a run's end, a keyboard arm) is not a retake.
    @Test func aLeaseMidInterruptionDoesNotClearTheLostHold() {
        var i = lost()
        i.leaseObserved()
        #expect(i.needsResume)
        #expect(i.backgroundTaskWanted)
        let retake = i.ended()
        #expect(retake)
    }

    @Test func aLeaseDuringTheRetakeLeavesItsOutcomeToTheRetake() {
        var i = lost()
        _ = i.ended()
        i.leaseObserved()
        #expect(i.needsResume)
        #expect(i.backgroundTaskWanted)
    }

    @Test func aLeaseAfterTheInterruptionSettlesTheLostHold() {
        var i = lost()
        _ = i.ended()
        _ = i.finishRetake(.failed, generation: i.generation)
        i.leaseObserved() // a keyboard arm in the foreground
        #expect(!i.needsResume)
        #expect(!i.backgroundTaskWanted)
    }

    // 2. A second began during an in-flight retake.
    @Test func aBeganDuringARetakeKeepsTheLostHoldAndTheBackgroundTask() {
        var i = lost()
        _ = i.ended()
        let first = i.generation
        i.began(wasHolding: false) // micReadyUntil is already nil
        let rerun = i.finishRetake(.failed, generation: first)
        #expect(!rerun)
        #expect(i.needsResume)
        #expect(i.backgroundTaskWanted) // interruption 2 is live
    }

    @Test func aSuccessfulStaleRetakeDoesNotClearTheHoldOfALaterInterruption() {
        var i = lost()
        _ = i.ended()
        let first = i.generation
        i.began(wasHolding: false)
        _ = i.finishRetake(.held, generation: first)
        #expect(i.needsResume)
    }

    @Test func anEndedDuringARetakeRerunsItAfterwards() {
        var i = lost()
        _ = i.ended()
        let first = i.generation
        i.began(wasHolding: false)
        let dropped = i.ended() // a retake is in flight
        let rerun = i.finishRetake(.failed, generation: first)
        #expect(!dropped)
        #expect(rerun)
        #expect(i.retaking)
        let third = i.finishRetake(.held, generation: i.generation)
        #expect(!third)
        #expect(!i.needsResume)
        #expect(!i.backgroundTaskWanted)
    }

    @Test func noRerunWhileTheLaterInterruptionIsStillLive() {
        var i = lost()
        _ = i.ended()
        let first = i.generation
        i.began(wasHolding: false)
        let rerun = i.finishRetake(.failed, generation: first)
        let retake = i.ended() // the real end starts the retake
        #expect(!rerun)
        #expect(retake)
    }

    @Test func foregroundDoesNotRetakeDuringAnInterruption() {
        var i = lost()
        let retake = i.foregrounded()
        #expect(!retake)
        #expect(!i.shouldResumeWhenForegrounded)
    }

    // 3. A dropped retake releases the task; the flag stays for the foreground.
    @Test func anAbandonedRetakeEndsTheTaskButKeepsTheFlag() {
        var i = lost()
        _ = i.ended()
        i.abandonRetake()
        #expect(!i.backgroundTaskWanted)
        #expect(i.shouldResumeWhenForegrounded)
    }

    @Test func theBackgroundTaskCoversInterruptionAndRetakeOnly() {
        var i = HoldInterruptions()
        #expect(!i.backgroundTaskWanted)
        i.began(wasHolding: true)
        #expect(i.backgroundTaskWanted)
        _ = i.ended()
        #expect(i.backgroundTaskWanted)
        _ = i.finishRetake(.failed, generation: i.generation)
        #expect(!i.backgroundTaskWanted)
    }

    // 5. Stale flags.
    @Test func switchingKeepReadyOffClearsTheLostHold() {
        var i = lost()
        let retake = i.ended(keepReady: false)
        #expect(!retake)
        #expect(!i.needsResume)

        var j = lost()
        _ = j.ended()
        _ = j.finishRetake(.failed, generation: j.generation)
        let again = j.foregrounded(keepReady: false)
        #expect(!again)
        #expect(!j.shouldResumeWhenForegrounded)
    }

    @Test func aBusyArmIsNotOursToRetake() {
        var i = lost()
        _ = i.ended()
        _ = i.finishRetake(.busy, generation: i.generation)
        #expect(!i.needsResume)
        #expect(!i.shouldResumeWhenForegrounded)
    }
}
