import Testing
@testable import LegatoAppServices

struct KeyboardHopStateTests {
    @Test func idleDuplicateCannotPresentProgressWithoutAnArmThatCanFinish() {
        let state = KeyboardHopState.resolve(runActive: false, microphoneReady: false, failure: nil, arming: false)
        guard case .failed = state else {
            Issue.record("A consumed or cancelled idle hop must have a terminal presentation, got \(state)")
            return
        }
    }

    @Test func activeArmHasProgressAndFinishedArmShowsReady() {
        #expect(KeyboardHopState.resolve(runActive: false, microphoneReady: false, failure: nil, arming: true) == .preparing)
        #expect(KeyboardHopState.resolve(runActive: false, microphoneReady: true, failure: nil, arming: false) == .ready)
        #expect(KeyboardHopState.resolve(runActive: false, microphoneReady: false, failure: "Cancelled", arming: false) == .failed("Cancelled"))
    }
}
