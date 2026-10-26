import Foundation

/// Long-press alternates, in iOS order. Pass the key's output; an uppercase letter gets uppercase alternates.
public enum Alternates {
    private static let table: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "-": ["–", "—", "•"],
        "\"": ["“", "”", "„", "»", "«"],
        "'": ["’", "‘", "‚", "›", "‹"],
        "$": ["€", "£", "¥", "¢", "₩"],
        "?": ["¿"],
        "!": ["¡"],
        "0": ["°"],
        "%": ["‰"],
        "=": ["≠", "≈"],
    ]

    public static func `for`(_ output: String) -> [String] {
        if let direct = table[output] { return direct }
        let lower = output.lowercased()
        guard lower != output, let base = table[lower] else { return [] }
        return base.map { $0 == "ß" ? "ẞ" : $0.uppercased() }
    }
}
