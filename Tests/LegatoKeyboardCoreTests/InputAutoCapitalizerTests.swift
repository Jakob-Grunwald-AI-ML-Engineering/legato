import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputAutoCapitalizerTests {
    private func ctx(_ s: String?) -> TextContext { TextContext(documentContextBeforeInput: s) }

    @Test func sentencesCapitalizeAtDocumentStart() {
        #expect(AutoCapitalizer.shouldCapitalize(.sentences, context: ctx(nil)))
        #expect(AutoCapitalizer.shouldCapitalize(.sentences, context: ctx("")))
    }

    @Test func sentencesCapitalizeAfterTerminatorsAndNewline() {
        for s in ["Hi. ", "Hi! ", "Hi? ", "Hi\n"] {
            #expect(AutoCapitalizer.shouldCapitalize(.sentences, context: ctx(s)), "\(s.debugDescription)")
        }
    }

    @Test func sentencesDoNotCapitalizeMidSentenceOrMidWord() {
        for s in ["Hi ", "Hi.", "Hi, ", "Hi. a", "Hi"] {
            #expect(!AutoCapitalizer.shouldCapitalize(.sentences, context: ctx(s)), "\(s.debugDescription)")
        }
    }

    @Test func wordsCapitalizeAtEachWordStart() {
        #expect(AutoCapitalizer.shouldCapitalize(.words, context: ctx("")))
        #expect(AutoCapitalizer.shouldCapitalize(.words, context: ctx("Hi ")))
        #expect(AutoCapitalizer.shouldCapitalize(.words, context: ctx("Hi\n")))
        #expect(!AutoCapitalizer.shouldCapitalize(.words, context: ctx("Hi")))
    }

    @Test func allCharactersAlways() {
        #expect(AutoCapitalizer.shouldCapitalize(.allCharacters, context: ctx("abc")))
        #expect(AutoCapitalizer.shouldCapitalize(.allCharacters, context: ctx(nil)))
    }

    @Test func noneNever() {
        #expect(!AutoCapitalizer.shouldCapitalize(.none, context: ctx(nil)))
        #expect(!AutoCapitalizer.shouldCapitalize(.none, context: ctx("Hi. ")))
    }
}
