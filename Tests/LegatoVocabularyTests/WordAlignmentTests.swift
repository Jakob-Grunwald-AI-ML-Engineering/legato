import Testing
@testable import LegatoVocabulary

@Suite struct WordAlignmentTests {
    typealias Block = WordAlignment.Block

    @Test func identicalTextsHaveNoBlocks() {
        #expect(WordAlignment.substitutions(from: "wir treffen uns morgen", to: "wir treffen uns morgen").isEmpty)
    }

    @Test func oneWordBecomesOneWord() {
        let blocks = WordAlignment.substitutions(from: "ask kloud about it", to: "ask Claude about it")
        #expect(blocks == [Block(raw: ["kloud"], target: ["Claude"])])
    }

    @Test func twoWordsBecomeOneWord() {
        let blocks = WordAlignment.substitutions(from: "we deploy on kuber netties today", to: "we deploy on Kubernetes today")
        #expect(blocks == [Block(raw: ["kuber", "netties"], target: ["Kubernetes"])])
    }

    @Test func oneWordBecomesTwoWords() {
        let blocks = WordAlignment.substitutions(from: "das ist der Grünwald", to: "das ist der Grün Wald")
        #expect(blocks == [Block(raw: ["Grünwald"], target: ["Grün", "Wald"])])
    }

    @Test func threeWordsBecomeThreeWords() {
        let blocks = WordAlignment.substitutions(from: "so a b c done", to: "so x y z done")
        #expect(blocks == [Block(raw: ["a", "b", "c"], target: ["x", "y", "z"])])
        #expect(blocks[0].rawText == "a b c")
        #expect(blocks[0].targetText == "x y z")
    }

    @Test func aSideOfFourWordsIsDropped() {
        #expect(WordAlignment.substitutions(from: "so a b c d done", to: "so x done").isEmpty)
        #expect(WordAlignment.substitutions(from: "so x done", to: "so a b c d done").isEmpty)
    }

    @Test func pureInsertionsAndDeletionsAreNotSubstitutions() {
        #expect(WordAlignment.substitutions(from: "ich komme", to: "ich komme morgen").isEmpty)
        #expect(WordAlignment.substitutions(from: "ich komme morgen", to: "ich komme").isEmpty)
    }

    @Test func caseAndPunctuationAreFoldedForAlignment() {
        let blocks = WordAlignment.substitutions(from: "hello, kloud code works.", to: "Hello Claude Code works!")
        #expect(blocks == [Block(raw: ["kloud"], target: ["Claude"])])
    }

    @Test func surfacesKeepTheirCaseButLoseEdgePunctuation() {
        let blocks = WordAlignment.substitutions(from: "Sag \"Kloud\", bitte", to: "Sag „Claude“, bitte")
        #expect(blocks == [Block(raw: ["Kloud"], target: ["Claude"])])
    }

    @Test func aDiacriticChangeIsASubstitutionForTheLearnerToFilter() {
        let blocks = WordAlignment.substitutions(from: "in Grunwald heute", to: "in Grünwald heute")
        #expect(blocks == [Block(raw: ["Grunwald"], target: ["Grünwald"])])
    }

    @Test func separateChangesGiveSeparateBlocks() {
        let blocks = WordAlignment.substitutions(from: "kloud and kuber netties", to: "Claude and Kubernetes")
        #expect(blocks == [Block(raw: ["kloud"], target: ["Claude"]), Block(raw: ["kuber", "netties"], target: ["Kubernetes"])])
    }

    @Test func emptyInputsGiveNoBlocks() {
        #expect(WordAlignment.substitutions(from: "", to: "").isEmpty)
        #expect(WordAlignment.substitutions(from: "", to: "hallo").isEmpty)
    }
}
