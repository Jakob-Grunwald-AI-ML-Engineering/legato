import Foundation

/// Recognises digits and spelled-out numbers (German and English), so that "13" ↔ "dreizehn" is never mistaken
/// for a vocabulary fix.
enum NumberWords {
    private static let numbers: Set<String> = [
        // German
        "null", "eins", "ein", "eine", "einen", "einem", "einer", "zwei", "zwo", "drei", "vier", "fünf", "fuenf",
        "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf", "zwoelf", "dreizehn", "vierzehn", "fünfzehn",
        "fuenfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn", "zwanzig", "dreißig", "dreissig", "vierzig",
        "fünfzig", "fuenfzig", "sechzig", "siebzig", "achtzig", "neunzig", "hundert", "tausend", "million",
        "millionen", "milliarde", "milliarden",
        // English
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "billion",
    ]
    private static let fillers: Set<String> = ["und", "and", "point", "comma", "komma", "minus", "plus"]
    private static let longestWord = 12

    /// Whether every word is a digit string, a number word or a connector, and at least one is a number.
    static func isPurelyNumeric(_ words: [String]) -> Bool {
        var real = false
        for word in words {
            switch classify(word) {
            case .number: real = true
            case .filler: break
            case .other: return false
            }
        }
        return real
    }

    /// Whether any word has a digit or is a spelled-out number ("3 PM", "5km", "zwei"): a number format change,
    /// a time or a quantity, never a vocabulary term.
    static func containsNumber(_ words: [String]) -> Bool {
        words.contains { $0.contains(where: \.isNumber) || classify($0) == .number }
    }

    private static let units: Set<String> = [
        "am", "pm", "a.m", "p.m", "uhr", "o'clock", "km", "kg", "cm", "mm", "ml", "mg", "kb", "mb", "gb", "tb", "hz", "khz",
        "mhz", "ghz",
    ]

    /// Whether any word is a unit or a time marker ("pm", "km", "Uhr").
    static func containsUnit(_ words: [String]) -> Bool { words.contains { units.contains($0.lowercased()) } }

    private enum Kind { case number, filler, other }

    private static func classify(_ word: String) -> Kind {
        let w = word.lowercased()
        if w.contains(where: \.isNumber), w.allSatisfy({ $0.isNumber || ",.%:/-+".contains($0) }) { return .number }
        if fillers.contains(w) { return .filler }
        let parts = w.split(separator: "-").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(segmentable) else { return .other }
        return .number
    }

    /// Whether `s` splits completely into number words and connectors ("dreiundzwanzig").
    private static func segmentable(_ s: String) -> Bool {
        let chars = Array(s)
        guard !chars.isEmpty else { return false }
        var ok = [Bool](repeating: false, count: chars.count + 1)
        ok[0] = true
        for end in 1...chars.count {
            for len in 1...min(longestWord, end) where ok[end - len] {
                let piece = String(chars[(end - len)..<end])
                if numbers.contains(piece) || fillers.contains(piece) {
                    ok[end] = true
                    break
                }
            }
        }
        guard ok[chars.count] else { return false }
        return !fillers.contains(s)
    }
}
