import Testing
@testable import LegatoMeetings

@Suite struct SummaryNamesTests {
    @Test func aWholeNameIsReplacedEverywhere() {
        let text = "**Speaker 1** proposed it. Speaker 1 owns the launch; Speaker 2 agreed."
        #expect(SummaryNames.replacing("Speaker 1", with: "Anna", in: text)
            == "**Anna** proposed it. Anna owns the launch; Speaker 2 agreed.")
    }

    @Test func aNameInsideALongerWordOrNumberStays() {
        #expect(SummaryNames.replacing("Speaker 1", with: "Anna", in: "Speaker 10 and Speaker 1.") == "Speaker 10 and Anna.")
        #expect(SummaryNames.replacing("Ann", with: "Anne", in: "Anna met Ann.") == "Anna met Anne.")
    }

    @Test func specialCharactersInNamesAreTakenLiterally() {
        #expect(SummaryNames.replacing("A.B.", with: "$1 (x)", in: "A.B. and AxBx") == "$1 (x) and AxBx")
    }

    @Test func anEmptyOrUnchangedNameChangesNothing() {
        #expect(SummaryNames.replacing("", with: "Anna", in: "text") == "text")
        #expect(SummaryNames.replacing("Anna", with: "Anna", in: "Anna") == "Anna")
    }
}
