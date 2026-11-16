import Testing
@testable import LegatoMac

struct NativeInputLeaseTests {
    @Test(arguments: [false, true]) func failedHomeNeverCapturesFurtherKeys(pending: Bool) {
        var lease = NativeInputLease()
        let admitted = lease.begin()
        #expect(admitted)
        lease.finish(homeVerified: false, hasPendingEvents: pending)
        #expect(lease.phase == .blocked)
        #expect(!lease.capturesInput)
        let readmitted = lease.begin()
        #expect(!readmitted)
    }
    @Test func idleTapDisableDoesNotCaptureOrBlockInput() {
        var lease = NativeInputLease()
        lease.disable(hasPendingEvents: false)
        #expect(lease.phase == .idle)
        #expect(!lease.capturesInput)
    }
    @Test func interruptedReplayDoesNotCaptureFurtherInputOrResumeWithoutProof() {
        var lease = NativeInputLease()
        let admitted = lease.begin()
        #expect(admitted)
        lease.finish(homeVerified: true, hasPendingEvents: true)
        #expect(lease.capturesInput)
        lease.disable(hasPendingEvents: true)
        lease.drained() // a late acknowledgement cannot reopen a failed replay
        #expect(lease.phase == .blocked)
        #expect(!lease.capturesInput)
        let unproved = lease.recover(verifiedClick: false, hasPendingEvents: true)
        #expect(!unproved)
        #expect(lease.phase == .blocked)
    }
    @Test func explicitVerifiedRecoveryReleasesOnlyExistingPendingInput() {
        var lease = NativeInputLease()
        let admitted = lease.begin()
        #expect(admitted)
        lease.finish(homeVerified: false, hasPendingEvents: true)
        let unproved = lease.recover(verifiedClick: false, hasPendingEvents: true)
        #expect(!unproved)
        let recovered = lease.recover(verifiedClick: true, hasPendingEvents: true)
        #expect(recovered)
        #expect(lease.phase == .replaying)
        lease.drained()
        #expect(lease.phase == .idle)
        #expect(!lease.capturesInput)
    }
}
