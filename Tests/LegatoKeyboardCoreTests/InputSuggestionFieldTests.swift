import Testing
@testable import LegatoKeyboardCore

@Suite struct InputSuggestionFieldTests {
    private func learns(
        fullAccess: Bool = true, secure: Bool = false, keyboard: SuggestionField.Keyboard = .default, contentType: String? = nil
    ) -> Bool {
        SuggestionField.learns(fullAccess: fullAccess, secure: secure, keyboard: keyboard, contentType: contentType)
    }

    private func suggests(
        secure: Bool = false, keyboard: SuggestionField.Keyboard = .default, contentType: String? = nil
    ) -> Bool {
        SuggestionField.suggests(secure: secure, keyboard: keyboard, contentType: contentType)
    }

    @Test func proseFieldsLearnWithFullAccess() {
        #expect(learns())
        #expect(learns(keyboard: .asciiCapable))
        #expect(learns(keyboard: .twitter))
        #expect(learns(contentType: "name"))
    }

    @Test func nothingIsLearnedWithoutFullAccessOrInASecureField() {
        #expect(!learns(fullAccess: false))
        #expect(!learns(secure: true))
    }

    @Test func keyboardsThatAreNotProseDoNotLearn() {
        #expect(!learns(keyboard: .other))
        #expect(!learns(keyboard: .numbersAndPunctuation))
        #expect(!learns(keyboard: .webSearch))
    }

    @Test(arguments: [
        "password", "newPassword", "oneTimeCode", "creditCardNumber", "creditCardSecurityCode", "username",
        "emailAddress", "URL", "telephoneNumber", "fullStreetAddress", "streetAddressLine1", "streetAddressLine2",
        "addressCity", "addressState", "addressCityAndState", "sublocality", "countryName", "postalCode",
    ])
    func contentTypesThatAreNotProseNeverLearn(_ type: String) {
        #expect(!learns(contentType: type))
    }

    @Test func aPasswordTypeOnADefaultKeyboardGetsNoSuggestionsEither() {
        #expect(!suggests(contentType: "password"))
        #expect(!suggests(contentType: "oneTimeCode"))
        #expect(!suggests(contentType: "creditCardNumber"))
    }

    @Test func proseFieldsGetSuggestions() {
        #expect(suggests())
        #expect(suggests(keyboard: .numbersAndPunctuation))
        #expect(suggests(contentType: "name"))
        #expect(!suggests(secure: true))
        #expect(!suggests(keyboard: .other))
    }

    @Test func contentTypeNamesAreComparedCaseInsensitively() {
        #expect(!learns(contentType: "USERNAME"))
    }
}
