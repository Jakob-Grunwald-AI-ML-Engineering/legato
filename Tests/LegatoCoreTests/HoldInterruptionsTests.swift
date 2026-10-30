import Testing
@testable import LegatoCore

@Suite struct HoldInterruptionsTests {
    @Test func endedWhileHoldingTriesToRetakeTheHold() {
        var i = HoldInterruptions()
        i.began(wasHolding: true)
        #expect(i.ended(shouldResume: true))
        i.resumed()
        #expect(!i.needsResume)
    }

    @Test func endedWithoutShouldResumeStillTriesOnceWhenHolding() {
        var i = HoldInterruptions()
        i.began(wasHolding: true)
        #expect(i.ended(shouldResume: false))
    }

    @Test func aFailedRetakeIsDeferredToTheNextForeground() {
        var i = HoldInterruptions()
        i.began(wasHolding: true)
        #expect(i.ended(shouldResume: true))
        i.resumeFailed()
        #expect(i.shouldResumeWhenForegrounded)
        i.resumed()
        #expect(!i.shouldResumeWhenForegrounded)
    }

    @Test func notHoldingNeverReactivates() {
        var i = HoldInterruptions()
        i.began(wasHolding: false)
        #expect(!i.ended(shouldResume: true))
        #expect(!i.shouldResumeWhenForegrounded)
    }

    @Test func aSecondInterruptionKeepsTheLostHold() {
        var i = HoldInterruptions()
        i.began(wasHolding: true)
        i.began(wasHolding: false) // the lease is already gone
        #expect(i.ended(shouldResume: true))
    }

    @Test func aRunningDictationCountsAsHoldingOnlyWhenItKeepsTheLease() {
        #expect(HoldInterruptions.wasHolding(leaseHeld: false, dictating: true, keepsLeaseAfterRun: false) == false)
        #expect(HoldInterruptions.wasHolding(leaseHeld: false, dictating: true, keepsLeaseAfterRun: true))
        #expect(HoldInterruptions.wasHolding(leaseHeld: true, dictating: false, keepsLeaseAfterRun: false))
        #expect(HoldInterruptions.wasHolding(leaseHeld: false, dictating: false, keepsLeaseAfterRun: true) == false)
    }
}
