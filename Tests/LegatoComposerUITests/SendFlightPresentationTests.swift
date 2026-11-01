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
    @Test func noOldViewportMeansNoReplayedFlightOnOpening() {
        var flight = SendFlightPresentation()
        let observed9 = flight.observe(acknowledgement: "delivered", hasDraft: false, hadDraft: false)
        #expect(!observed9)
        #expect(!flight.retainsViewport(acknowledgement: "delivered", hasDraft: false, hadDraft: false))
    }
}
