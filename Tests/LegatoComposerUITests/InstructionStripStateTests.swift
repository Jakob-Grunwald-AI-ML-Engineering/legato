import Testing
@testable import LegatoComposerUI

@Test func instructionStatusMapsToStripState() {
    #expect(InstructionStripState(status: "Ready") == .idle)
    #expect(InstructionStripState(status: "Listening") == .listening)
    #expect(InstructionStripState(status: "Applying") == .applying)
    #expect(InstructionStripState(status: "Done") == .applied)
    #expect(InstructionStripState(status: "Failed") == .failed)
    #expect(InstructionStripState(status: "No bound text field. Draft kept.") == .notice("No bound text field. Draft kept."))
}

@Test func sendRimFillsBetweenCountdownStartAndDeadline() {
    #expect(InstructionSendButton.progress(now: 10, start: nil, deadline: nil) == nil)
    #expect(InstructionSendButton.progress(now: 10, start: 10, deadline: 12) == 0)
    #expect(InstructionSendButton.progress(now: 11, start: 10, deadline: 12) == 0.5)
    #expect(InstructionSendButton.progress(now: 20, start: 10, deadline: 12) == 1)
}
