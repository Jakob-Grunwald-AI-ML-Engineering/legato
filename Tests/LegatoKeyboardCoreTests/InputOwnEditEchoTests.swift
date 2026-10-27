import Testing
@testable import LegatoKeyboardCore

@Suite struct InputOwnEditEchoTests {
    @Test func equalContextsAreTheSameEdit() {
        #expect(OwnEditEcho.isSame(expected: "Say hello ", reported: "Say hello "))
        #expect(OwnEditEcho.isSame(expected: "", reported: ""))
    }

    @Test func aHostThatTrimsItsContextStillMatches() {
        #expect(OwnEditEcho.isSame(expected: "A long sentence ends here", reported: "ends here"))
        #expect(OwnEditEcho.isSame(expected: "ends here", reported: "A long sentence ends here"))
    }

    @Test func anEmptyExpectedContextDoesNotMatchAnyReportedText() {
        // After the keyboard emptied the field, a report with text before the cursor is the user moving about.
        #expect(!OwnEditEcho.isSame(expected: "", reported: "Hello "))
    }

    @Test func anEmptyReportDoesNotMatchTextEither() {
        #expect(!OwnEditEcho.isSame(expected: "Hello ", reported: ""))
    }

    @Test func differentTextIsForeign() {
        #expect(!OwnEditEcho.isSame(expected: "ab cd", reported: "ab"))
    }
}
