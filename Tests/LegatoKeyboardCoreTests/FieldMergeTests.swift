import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldMergeTests {
    private func rebase(_ base: String, kept: String, incoming: String) -> (String, Int) {
        let r = FieldMerge.rebase(base: Array(base), kept: Array(kept), incoming: Array(incoming))
        return (String(r.text), r.dropped)
    }

    @Test func punctuationAfterAWordTheUserShortenedLands() {
        #expect(rebase("before afternoon", kept: "before afterno", incoming: "before afternoon.") == ("before afterno.", 0))
    }

    @Test func punctuationAfterAWordTheUserDeletedIsDropped() {
        #expect(rebase("team before Friday", kept: "team before ", incoming: "team before Friday,") == ("team before ", 1))
    }

    @Test func untouchedWordsStillChange() {
        #expect(rebase("please send the whole report", kept: "please send the whol report", incoming: "Please send the whole Report.")
                == ("Please send the whol Report.", 0))
    }

    @Test func aChangeToTheUsersWordIsDropped() {
        #expect(rebase("alpha beta", kept: "alpha beZta", incoming: "alpha gamma") == ("alpha beZta", 1))
        // Glued onto the user's word.
        #expect(rebase("the who", kept: "the wh", incoming: "the whole") == ("the wh", 1))
    }

    @Test func bothInsertingAtOnePlaceKeepsKept() {
        #expect(rebase("send the report", kept: "Sende den Bericht.", incoming: "Send the report.").0 == "Sende den Bericht.")
    }
}
