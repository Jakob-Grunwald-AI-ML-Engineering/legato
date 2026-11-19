import Testing
@testable import LegatoKeyboardCore

@Suite struct ManualLiveRunTests {
    private let sentence = "we should ship it on friday after the review."

    @Test func anAutoRunClosesAUnitAtASentenceEnd() {
        var run = LiveDictationRun(staged: true)
        #expect(run.addFinal(key: 0, text: sentence) != nil)
    }

    @Test func aManualRunNeverClosesAUnitAtASentenceEnd() {
        var run = LiveDictationRun(staged: true, manual: true)
        #expect(run.addFinal(key: 0, text: sentence) == nil)
        #expect(run.addFinal(key: 1, text: "and then we celebrate with the whole team.") == nil)
        #expect(run.unitCount == 1)
    }

    @Test func aManualRunDoesNotCloseAtTheWordCap() {
        var run = LiveDictationRun(staged: true, manual: true)
        let words = Array(repeating: "word", count: LiveDictationRun.maxUnitWords + 5).joined(separator: " ")
        #expect(run.addFinal(key: 0, text: words) == nil)
    }

    @Test func flushTakesEverythingTheManualRunHolds() throws {
        var run = LiveDictationRun(staged: true, manual: true)
        run.addFinal(key: 0, text: sentence)
        run.addFinal(key: 1, text: "uh and the budget")
        let flushed = run.flush()
        let open = try #require(flushed)
        #expect(open.key == 1 && open.text == "we should ship it on friday after the review. uh and the budget")
        // Words after the send start the next unit.
        run.addFinal(key: 2, text: "next thing")
        #expect(run.unitCount == 2)
    }
}
