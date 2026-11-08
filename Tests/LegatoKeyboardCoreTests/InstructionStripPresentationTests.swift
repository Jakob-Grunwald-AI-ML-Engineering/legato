import Testing
@testable import LegatoKeyboardCore

@Suite struct InstructionStripPresentationTests {
    private func present(_ phase: InstructionStrip.Phase, transcript: String = "", message: String? = nil, canUndo: Bool = false,
                         reading: Bool = false, magic: MagicToggle = .off) -> InstructionStripPresentation? {
        InstructionStripPresentation(strip: InstructionStrip(phase: phase, transcript: transcript, message: message, canUndo: canUndo),
                                     isReadingField: reading, magic: magic)
    }

    @Test func idleShowsNothingUnlessTheKeyIsOn() {
        #expect(InstructionStripPresentation(strip: nil, isReadingField: false, magic: .off) == nil)
        #expect(present(.idle) == nil)
        #expect(present(.idle, magic: .latched)?.kind == .listening)
    }

    @Test func listeningShowsTheTranscriptOrAPrompt() {
        let said = present(.listening, transcript: " make it shorter ")
        #expect(said?.text == "make it shorter" && said?.isTranscript == true)
        #expect(present(.listening)?.text == InstructionStripPresentation.listeningPrompt)
        #expect(present(.listening)?.isTranscript == false)
    }

    @Test func theWalkOfTheFieldWinsOverTheStrip() {
        #expect(present(.listening, transcript: "x", reading: true)?.kind == .reading)
        #expect(present(.idle, reading: true)?.text == InstructionStripPresentation.readingText)
    }

    @Test func aResultOffersAcceptAndUndoOnlyWhenItCanBeUndone() {
        let kept = present(.result, message: "Rewrote the paragraph.", canUndo: true)
        #expect(kept?.showsAccept == true && kept?.showsUndo == true && kept?.text == "Rewrote the paragraph.")
        #expect(present(.result)?.showsUndo == false)
    }

    @Test func aFailureOffersRetryAndUndoWhenKnown() {
        let failed = present(.failed, message: "The text changed.", canUndo: true)
        #expect(failed?.showsRetry == true && failed?.showsUndo == true && failed?.showsAccept == false)
        #expect(present(.failed)?.showsUndo == false)
    }

    @Test func aKeystrokeKeepsAResultAndLetsAFailureGo() {
        #expect(present(.result)?.keystrokeAction == .accept)
        #expect(present(.undone)?.keystrokeAction == .accept)
        #expect(present(.failed)?.keystrokeAction == .dismiss)
        #expect(present(.running)?.keystrokeAction == nil)
        #expect(present(.listening, transcript: "x")?.keystrokeAction == nil)
    }
}
