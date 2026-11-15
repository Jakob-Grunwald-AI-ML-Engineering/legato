import Foundation
import Testing
@testable import LegatoKeyboardCore

@Test func dictationStatusRoundTripsWithoutACompositionDocument() {
    let channel = DictationStatusLink(store: LinkStore(MemoryLinkStore()))
    var status = DictationStatus()
    status.audioRoute = .dictation
    status.dictationTake = "Keep these words"
    status.dictationTakePhase = .failed
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
