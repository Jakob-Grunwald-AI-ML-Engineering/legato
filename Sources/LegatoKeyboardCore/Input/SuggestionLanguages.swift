import Foundation

/// The languages the word row suggests in.
public enum SuggestionLanguages {
    /// The bare language codes ("de", "en") of the dictation languages the user chose (`stored`, locale
    /// identifiers), else of the system's preferred languages; "en" when there are none. No repeats.
    public static func codes(stored: [String], system: [String]) -> [String] {
        var seen = Set<String>()
        let codes = (stored.isEmpty ? system : stored)
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .filter { seen.insert($0).inserted }
        return codes.isEmpty ? ["en"] : codes
    }
}
