import Foundation
import Testing
@testable import LegatoCore

@Suite struct DictationResultTests {
    private let at = Date(timeIntervalSince1970: 1_000)

    @Test func aResultIsActionableUntilItsLifetimeEnds() {
        let result = DictationResult(runID: "run-1", text: "hello", at: at)
        #expect(result.isActionable(now: at))
        #expect(result.isActionable(now: at.addingTimeInterval(DictationResult.lifetime - 1)))
        #expect(!result.isActionable(now: at.addingTimeInterval(DictationResult.lifetime + 1)))
    }

    @Test func aResultWithoutTextIsNeverActionable() {
        #expect(!DictationResult(runID: "run-1", text: "", at: at).isActionable(now: at))
    }

    @Test func onlyTheResultAndFailedInsertStatesOfferTheButtons() {
        let offering = DictationPhase.allCases.filter(\.offersResultActions)
        #expect(Set(offering) == [.result, .insertFailed])
    }

    @Test(arguments: [
        (ResultOutcome.inserted, DictationPhase.inserted),
        (.keyboardNotActive, .insertFailed),
        (.copied, .copied),
        (.copyFailed, .tapToCopy),
    ])
    func eachOutcomeMapsToTheActivitysNextState(outcome: ResultOutcome, phase: DictationPhase) {
        #expect(outcome.phase == phase)
    }

    @Test func aFailedInsertKeepsTheButtonsAndEveryOtherOutcomeEndsTheActivity() {
        #expect(!ResultOutcome.keyboardNotActive.endsActivity)
        #expect(ResultOutcome.inserted.endsActivity)
        #expect(ResultOutcome.copied.endsActivity)
        #expect(ResultOutcome.copyFailed.endsActivity)
    }
}
