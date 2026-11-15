import Testing
@testable import LegatoKeyboardCore

@Suite struct FieldInsertionTests {
    @Test func boundariesPreserveExistingWhitespaceAndPunctuation() {
        #expect(FieldInsertion.separator(before: "Fresh", after: nil) == "")
        #expect(FieldInsertion.separator(before: "Fresh", after: "p") == " ")
        #expect(FieldInsertion.trailingSeparator(after: "Fresh Water", before: "K") == " ")
        #expect(FieldInsertion.trailingSeparator(after: "Fresh Water", before: ".") == "")
        #expect(FieldInsertion.trailingSeparator(after: "Fresh Water ", before: "K") == "")
        #expect(FieldInsertion.trailingSeparator(after: "Fresh Water", before: "\n") == "")
        #expect(FieldInsertion.separator(before: "…", after: "r") == "")
    }
}
