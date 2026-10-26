import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputTextContextTests {
    @Test func nilContextIsEmptyAndAtSentenceStart() {
        let c = TextContext(documentContextBeforeInput: nil)
        #expect(c.wordPrefix == "")
        #expect(c.lastCharacter == nil)
        #expect(c.isSentenceStart)
    }

    @Test func wordPrefixIsTheTrailingWord() {
        #expect(TextContext(documentContextBeforeInput: "Hello wor").wordPrefix == "wor")
        #expect(TextContext(documentContextBeforeInput: "Hello ").wordPrefix == "")
        #expect(TextContext(documentContextBeforeInput: "don't").wordPrefix == "don't")
        #expect(TextContext(documentContextBeforeInput: "Hi.\nüb").wordPrefix == "üb")
        #expect(TextContext(documentContextBeforeInput: "Hello,").wordPrefix == "")
    }

    @Test func lastCharacter() {
        #expect(TextContext(documentContextBeforeInput: "ab ").lastCharacter == " ")
        #expect(TextContext(documentContextBeforeInput: "ab").lastCharacter == "b")
    }

    @Test func sentenceStartAfterTerminatorAndSpace() {
        #expect(TextContext(documentContextBeforeInput: "Hi. ").isSentenceStart)
        #expect(TextContext(documentContextBeforeInput: "Hi! ").isSentenceStart)
        #expect(TextContext(documentContextBeforeInput: "Hi? ").isSentenceStart)
        #expect(TextContext(documentContextBeforeInput: "Hi.  ").isSentenceStart)
    }

    @Test func sentenceStartAfterNewline() {
        #expect(TextContext(documentContextBeforeInput: "Hi\n").isSentenceStart)
        #expect(TextContext(documentContextBeforeInput: "Hi\n ").isSentenceStart)
    }

    @Test func notSentenceStartMidSentence() {
        #expect(!TextContext(documentContextBeforeInput: "Hi ").isSentenceStart)
        #expect(!TextContext(documentContextBeforeInput: "Hi.").isSentenceStart)
        #expect(!TextContext(documentContextBeforeInput: "Hi, ").isSentenceStart)
        #expect(!TextContext(documentContextBeforeInput: "Hi. a").isSentenceStart)
    }

    @Test func whitespaceOnlyCountsAsStart() {
        #expect(TextContext(documentContextBeforeInput: "  ").isSentenceStart)
    }
}
