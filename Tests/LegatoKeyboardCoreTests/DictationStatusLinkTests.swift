import Foundation
import Testing
@testable import LegatoKeyboardCore

@Test func dictationStatusRoundTripsWithoutACompositionDocument() {
    let channel = DictationStatusLink(store: LinkStore(MemoryLinkStore()))
    var status = DictationStatus()
    status.audioRoute = .dictation
    status.dictationTake = "Keep these words"
    status.dictationTakePhase = .failed
    // Binary-exact in both Date's reference epoch and the link's seconds-since-1970 encoding.
    // This checks the complete wire value without depending on wall-clock conversion rounding.
    status.fieldCleanupOutcome = .init(runID: "confirmed-take", revision: 2, status: .cleaned,
                                      at: Date(timeIntervalSince1970: 1_700_000_000.25))
    channel.publish(status)
    #expect(channel.read() == status)
}

@Test func dictationControlsAreTypedAndConsumedOnceInOrder() {
    let channel = DictationStatusLink(store: LinkStore(MemoryLinkStore()))
    var stop = DictationControl(action: .stop)
    stop.timestamp = 1
    var retry = DictationControl(action: .retry)
    retry.timestamp = 2
    channel.send(retry)
    channel.send(stop)
    #expect(channel.drainIntents() == [stop, retry])
    #expect(channel.drainIntents().isEmpty)
}
