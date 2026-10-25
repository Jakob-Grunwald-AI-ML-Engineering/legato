import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputSpaceRulesTests {
    private let t = Date(timeIntervalSince1970: 1_000)
    private func ctx(_ s: String?) -> TextContext { TextContext(documentContextBeforeInput: s) }

    @Test func doubleSpaceAfterAWordMakesPeriod() {
        let r = SpaceRules.spaceTapped(context: ctx("Hello "), lastSpaceAt: t, now: t.addingTimeInterval(0.39))
        #expect(r == .replacePreviousSpaceWithPeriodSpace)
    }

    @Test func slowSecondSpaceIsPlain() {
        let r = SpaceRules.spaceTapped(context: ctx("Hello "), lastSpaceAt: t, now: t.addingTimeInterval(0.41))
        #expect(r == .insertSpace)
    }

    @Test func noPeriodAfterPunctuation() {
        for s in ["Hello. ", "Hello, ", "Hello! ", "Hello? ", "Hi) "] {
            let r = SpaceRules.spaceTapped(context: ctx(s), lastSpaceAt: t, now: t.addingTimeInterval(0.1))
            #expect(r == .insertSpace, "\(s)")
        }
    }

    @Test func noPeriodAtStartOrAfterNewlineOrExtraSpaces() {
        for s in [" ", "\n ", "Hello  ", ""] {
            let r = SpaceRules.spaceTapped(context: ctx(s), lastSpaceAt: t, now: t.addingTimeInterval(0.1))
            #expect(r == .insertSpace, "\(s.debugDescription)")
        }
    }

    @Test func noPreviousSpaceTapIsPlain() {
        let r = SpaceRules.spaceTapped(context: ctx("Hello "), lastSpaceAt: nil, now: t)
        #expect(r == .insertSpace)
    }

    @Test func previousCharMustBeASpace() {
        let r = SpaceRules.spaceTapped(context: ctx("Hello"), lastSpaceAt: t, now: t.addingTimeInterval(0.1))
        #expect(r == .insertSpace)
    }

    @Test func digitsCountAsWords() {
        let r = SpaceRules.spaceTapped(context: ctx("In 2024 "), lastSpaceAt: t, now: t.addingTimeInterval(0.1))
        #expect(r == .replacePreviousSpaceWithPeriodSpace)
    }
}
