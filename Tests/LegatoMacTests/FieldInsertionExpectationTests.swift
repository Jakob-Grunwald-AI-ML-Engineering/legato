import Testing
@testable import LegatoMac

@Suite struct FieldInsertionExpectationTests {
    @Test func ignoredKeysNeverCountAsDeliveryEvenIfTheSuffixAlreadyMatches() {
        let proof = FieldInsertionExpectation(text: "same", selection: .init(location: 4, length: 0), length: 4)!
        #expect(!proof.matches(selection: .init(location: 4, length: 0), length: 4, insertedText: "same", normalizeSpaces: false))
        #expect(proof.matches(selection: .init(location: 8, length: 0), length: 8, insertedText: "same", normalizeSpaces: false))
    }

    @Test func replacementConfirmsItsRangeLengthAndCaret() {
        let proof = FieldInsertionExpectation(text: "new", selection: .init(location: 2, length: 5), length: 10)!
        #expect(proof.insertedRange == .init(location: 2, length: 3))
        #expect(proof.length == 8)
        #expect(proof.matches(selection: .init(location: 5, length: 0), length: 8, insertedText: "new", normalizeSpaces: false))
        #expect(!proof.matches(selection: .init(location: 5, length: 0), length: nil, insertedText: "new", normalizeSpaces: false))
        #expect(!proof.matches(selection: .init(location: 5, length: 0), length: 8, insertedText: nil, normalizeSpaces: false))
    }

    @Test func keyFieldsMayRepresentSpacesAsNonbreakingSpaces() {
        let proof = FieldInsertionExpectation(text: "a b", selection: .init(location: 0, length: 0), length: 0)!
        #expect(proof.matches(selection: proof.caret, length: 3, insertedText: "a\u{00A0}b", normalizeSpaces: true))
        #expect(!proof.matches(selection: proof.caret, length: 3, insertedText: "a\u{00A0}b", normalizeSpaces: false))
    }
}
