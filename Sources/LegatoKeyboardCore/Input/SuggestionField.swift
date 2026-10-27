import Foundation

/// Which fields get word suggestions, and which may be learned from. Pure: the keyboard maps the field's
/// traits (`UIKeyboardType`, `UITextContentType.rawValue`) to these arguments.
public enum SuggestionField {
    /// The keyboard types the word row cares about.
    public enum Keyboard: Sendable, Equatable {
        case `default`, asciiCapable, twitter, webSearch, numbersAndPunctuation
        /// Number, phone, decimal, email, URL, name-phone and the like: not prose.
        case other
    }

    /// Content types (`UITextContentType.rawValue`) that are credentials, identities, payment or contact
    /// details: nothing is suggested or learned there, whatever the keyboard type says.
    private static let sensitiveContentTypes: Set<String> = [
        "password", "newpassword", "onetimecode", "username", "emailaddress", "url", "telephonenumber",
        "fullstreetaddress", "streetaddressline1", "streetaddressline2", "addresscity", "addressstate",
        "addresscityandstate", "sublocality", "countryname", "postalcode", "location",
    ]

    /// Whether `contentType` marks a field that is not prose. Anything credit-card is sensitive.
    public static func isSensitive(contentType: String?) -> Bool {
        guard let key = contentType?.lowercased(), !key.isEmpty else { return false }
        return sensitiveContentTypes.contains(key) || key.hasPrefix("creditcard")
    }

    /// Whether the field takes suggestions: prose-like fields only (a password, address, number or URL doesn't).
    public static func suggests(secure: Bool, keyboard: Keyboard, contentType: String?) -> Bool {
        guard !secure, !isSensitive(contentType: contentType) else { return false }
        switch keyboard {
        case .default, .asciiCapable, .twitter, .webSearch, .numbersAndPunctuation: return true
        case .other: return false
        }
    }

    /// Whether what is typed here may be learned: Full Access, prose-like fields only.
    public static func learns(fullAccess: Bool, secure: Bool, keyboard: Keyboard, contentType: String?) -> Bool {
        guard fullAccess, !secure, !isSensitive(contentType: contentType) else { return false }
        switch keyboard {
        case .default, .asciiCapable, .twitter: return true
        case .webSearch, .numbersAndPunctuation, .other: return false
        }
    }
}
