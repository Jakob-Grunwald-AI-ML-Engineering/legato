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

    @Test func knownHunksDecideWhoseALetterIs() {
        // The user deleted " r" after "delta" and typed "ax": the diff would take the first "a" for the keyboard's.
        let cells: [FieldQueue.Cell] = Array("delt").map { .own($0) } + [.gone("a"), .gone(" "), .gone("r"), .user("a"), .user("x")]
            + Array("iver").map { .own($0) }
        let view = FieldQueue.ownView(cells)
        #expect(String(view.own) == "delta river")
        let r = FieldMerge.rebase(base: view.own, kept: Array("deltaxiver"), incoming: Array("delts river"), keptHunks: view.userHunks)
        #expect(String(r.text) == "deltaxiver")
        #expect(r.dropped == 1)
    }
}
