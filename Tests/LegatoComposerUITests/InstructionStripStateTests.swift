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
