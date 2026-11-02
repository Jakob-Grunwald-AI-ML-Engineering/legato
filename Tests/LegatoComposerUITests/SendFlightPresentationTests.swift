import Testing
@testable import LegatoComposerUI

struct SendFlightPresentationTests {
    @Test func successfulAcknowledgementWaitsForClearAndFliesOnlyOnce() {
        var flight = SendFlightPresentation()
        let observed0 = flight.observe(acknowledgement: "delivered", hasDraft: true, hadDraft: true)
        #expect(!observed0)
        #expect(flight.retainsViewport(acknowledgement: "delivered", hasDraft: false, hadDraft: true))
        let observed1 = flight.observe(acknowledgement: "delivered", hasDraft: false, hadDraft: true)
        #expect(observed1)
        #expect(flight.activeAcknowledgement == "delivered")
        let observed2 = flight.observe(acknowledgement: "delivered", hasDraft: false, hadDraft: true)
        #expect(!observed2)
        flight.finish("delivered")
        #expect(!flight.retainsViewport(acknowledgement: "delivered", hasDraft: false, hadDraft: true))
    }
    @Test func failedInsertAndClearHaveNoSuccessfulAcknowledgement() {
        var flight = SendFlightPresentation()
        let observed3 = flight.observe(acknowledgement: nil, hasDraft: true, hadDraft: true)
        #expect(!observed3)
        #expect(!flight.retainsViewport(acknowledgement: nil, hasDraft: false, hadDraft: true))
        let observed4 = flight.observe(acknowledgement: nil, hasDraft: false, hadDraft: true)
        #expect(!observed4)
        #expect(flight.activeAcknowledgement == nil)
    }
    @Test func priorDeliveryCannotAnimateClearOrNewTopic() {
        var flight = SendFlightPresentation()
        flight.reset(acknowledgement: "old-delivery")
        #expect(!flight.retainsViewport(acknowledgement: "old-delivery", hasDraft: false, hadDraft: true))
        let observed5 = flight.observe(acknowledgement: "old-delivery", hasDraft: false, hadDraft: true)
        #expect(!observed5)
    }
    @Test func newDraftCancelsFlightAndOldCompletionCannotFinishNewDelivery() {
        var flight = SendFlightPresentation()
        let observed6 = flight.observe(acknowledgement: "one", hasDraft: false, hadDraft: true)
        #expect(observed6)
        let observed7 = flight.observe(acknowledgement: "one", hasDraft: true, hadDraft: true)
        #expect(!observed7)
        #expect(flight.activeAcknowledgement == nil)
        let observed8 = flight.observe(acknowledgement: "two", hasDraft: false, hadDraft: true)
        #expect(observed8)
        flight.finish("one")
        #expect(flight.activeAcknowledgement == "two")
    }
    /// #225 hypothesis 1: a flight can never hide a draft that exists, whatever state it is stuck in.
    @Test func retainedViewportNeverAppliesWhileADraftExists() {
        var flight = SendFlightPresentation()
        _ = flight.observe(acknowledgement: "one", hasDraft: false, hadDraft: true)
        #expect(flight.activeAcknowledgement == "one")
        for acknowledgement in [nil, "one", "two"] as [String?] {
            #expect(!flight.retainsViewport(acknowledgement: acknowledgement, hasDraft: true, hadDraft: true))
        }
    }
    /// #225 hypothesis 1: a cancelled flight task (view disappeared) leaves the viewport retained for an empty
    /// draft until `abandon`; after it, the same acknowledgement neither retains nor replays.
    @Test func abandonedFlightReleasesViewportAndDoesNotReplay() {
        var flight = SendFlightPresentation()
        _ = flight.observe(acknowledgement: "one", hasDraft: false, hadDraft: true)
        #expect(flight.retainsViewport(acknowledgement: "one", hasDraft: false, hadDraft: true))
        flight.abandon()
        #expect(flight.activeAcknowledgement == nil)
        #expect(!flight.retainsViewport(acknowledgement: "one", hasDraft: false, hadDraft: true))
        let replay = flight.observe(acknowledgement: "one", hasDraft: false, hadDraft: true)
        #expect(!replay)
    }
    @Test func noOldViewportMeansNoReplayedFlightOnOpening() {
        var flight = SendFlightPresentation()
        let observed9 = flight.observe(acknowledgement: "delivered", hasDraft: false, hadDraft: false)
        #expect(!observed9)
        #expect(!flight.retainsViewport(acknowledgement: "delivered", hasDraft: false, hadDraft: false))
    }
}
