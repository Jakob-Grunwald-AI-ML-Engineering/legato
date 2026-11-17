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

    /// Both writers appended the same words, each diff placing them its own way ("holds" + ". Yeah" + "." against
    /// "holds." + " Yeah."; or a revision's word change that ends with the words speech appended): typed once
    /// (#299 recheck, Safari contenteditable: "Yeah. Yeah.").
    @Test func theSameAppendFromBothIsTypedOnce() {
        #expect(rebase("if the whether holds.", kept: "if the whether holds. Yeah.", incoming: "if the weather holds. Yeah.").0
            == "if the weather holds. Yeah.")
        #expect(rebase("the whether", kept: "the whether holds.", incoming: "the weather holds.").0 == "the weather holds.")
        // Different words appended by each still keep kept's.
        #expect(rebase("the whether", kept: "the whether holds.", incoming: "the weather stays.").0 != "the weather holds. stays.")
    }
}
