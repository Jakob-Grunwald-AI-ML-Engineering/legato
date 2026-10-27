import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutSuggestionSlotsTests {
    @Test(arguments: [
        ([], [nil, nil, nil]),
        (["best"], [nil, "best", nil]),
        (["best", "second"], ["second", "best", nil]),
        (["best", "second", "third"], ["second", "best", "third"]),
        (["best", "second", "third", "fourth"], ["second", "best", "third"]),
    ] as [([String], [String?])])
    func theBestSuggestionTakesTheMiddleSlot(ranked: [String], slots: [String?]) {
        #expect(SuggestionSlots.arrange(ranked) == slots)
    }
}
