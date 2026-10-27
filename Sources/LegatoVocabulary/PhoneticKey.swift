import Foundation

/// Phonetic keys for matching a misheard word to a vocabulary term: Kölner Phonetik for German and Metaphone
/// for English. Two words whose key agrees in either scheme sound alike enough to be worth comparing.
public enum PhoneticKey {
    // MARK: Kölner Phonetik

    /// The Kölner Phonetik code of `word` (digits 0–8), per the standard rules.
    ///
    /// Umlauts count as their base vowel, `ß` as `s`, other diacritics are folded; anything that is not a
    /// letter is skipped. Repeated codes collapse and `0` (vowels) survives only at the start. Words of
    /// several parts ("kuber netties") are coded as one word.
    public static func koelner(_ word: String) -> String {
        let letters = Array(foldedLetters(word))
        var codes: [Character] = []
        for (i, ch) in letters.enumerated() {
            let prev: Character? = i > 0 ? letters[i - 1] : nil
            let next: Character? = i + 1 < letters.count ? letters[i + 1] : nil
            switch ch {
            case "a", "e", "i", "j", "o", "u", "y": codes.append("0")
            case "h": break
            case "b": codes.append("1")
            case "p": codes.append(next == "h" ? "3" : "1")
            case "d", "t": codes.append(next.map { "csz".contains($0) } == true ? "8" : "2")
            case "f", "v", "w": codes.append("3")
            case "g", "k", "q": codes.append("4")
            case "c":
                if prev == nil {
                    codes.append(next.map { "ahkloqrux".contains($0) } == true ? "4" : "8")
                } else if let p = prev, "sz".contains(p) {
                    codes.append("8")
                } else {
                    codes.append(next.map { "ahkoqux".contains($0) } == true ? "4" : "8")
                }
            case "x":
                if let p = prev, "ckq".contains(p) { codes.append("8") } else { codes.append(contentsOf: ["4", "8"]) }
            case "l": codes.append("5")
            case "m", "n": codes.append("6")
            case "r": codes.append("7")
            case "s", "z": codes.append("8")
            default: break
            }
        }
        var out = ""
        var last: Character?
        for c in codes where c != last {
            last = c
            if c != "0" || out.isEmpty { out.append(c) }
        }
        return out
    }

    // MARK: Metaphone

    /// The Metaphone code of `word` (Lawrence Philips, 1990), cut to `maxLength` characters.
    ///
    /// Non-letters are skipped; diacritics and umlauts are folded to their base letters.
    public static func metaphone(_ word: String, maxLength: Int = 8) -> String {
        let w = Array(foldedLetters(word).uppercased())
        guard !w.isEmpty else { return "" }
        func at(_ i: Int) -> Character? { i >= 0 && i < w.count ? w[i] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { "AEIOU".contains($0) } ?? false }

        var out = ""
        var i = 0
        // Initial exceptions.
        switch (w[0], at(1)) {
        case ("A", "E"): out.append("E"); i = 2
        case ("G", "N"), ("K", "N"), ("P", "N"): i = 1
        case ("W", "R"): out.append("R"); i = 2
        case ("X", _): out.append("S"); i = 1
        case ("W", "H"):
            if isVowel(at(2)) { out.append("W") }
            i = 2
        default: break
        }
        while i < w.count, out.count < maxLength {
            let c = w[i]
            if c == at(i - 1), c != "C" {
                i += 1
                continue
            }
            var step = 1
            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { out.append(c) }
            case "B":
                if !(at(i - 1) == "M" && i == w.count - 1) { out.append("B") }
            case "C":
                if at(i + 1) == "I", at(i + 2) == "A" {
                    out.append("X")
                } else if at(i + 1) == "H" {
                    out.append("X")
                    step = 2
                } else if let n = at(i + 1), "IEY".contains(n) {
                    if at(i - 1) != "S" { out.append("S") }
                } else {
                    out.append("K")
                }
            case "D":
                if at(i + 1) == "G", let n = at(i + 2), "EIY".contains(n) {
                    out.append("J")
                    step = 2
                } else {
                    out.append("T")
                }
            case "G":
                if at(i + 1) == "H" {
                    // GH is silent unless a vowel follows (GHENT); the H itself is silent after G.
                    if isVowel(at(i + 2)) { out.append("K") }
                } else if at(i + 1) == "N" {
                    let endsHere = i + 2 == w.count || (at(i + 2) == "E" && at(i + 3) == "D" && i + 4 == w.count)
                    if !endsHere { out.append("K") }
                } else if let n = at(i + 1), "IEY".contains(n), at(i - 1) != "G" {
                    out.append("J")
                } else {
                    out.append("K")
                }
            case "H":
                if isVowel(at(i + 1)), !(at(i - 1).map { "CGPST".contains($0) } ?? false) { out.append("H") }
            case "K":
                if at(i - 1) != "C" { out.append("K") }
            case "P":
                if at(i + 1) == "H" {
                    out.append("F")
                    step = 2
                } else {
                    out.append("P")
                }
            case "Q": out.append("K")
            case "S":
                if at(i + 1) == "H" {
                    out.append("X")
                    step = 2
                } else if at(i + 1) == "I", let n = at(i + 2), n == "O" || n == "A" {
                    out.append("X")
                } else if at(i + 1) == "C", at(i + 2) == "H" {
                    out.append("SK")
                    step = 3
                } else {
                    out.append("S")
                }
            case "T":
                if at(i + 1) == "I", let n = at(i + 2), n == "O" || n == "A" {
                    out.append("X")
                } else if at(i + 1) == "H" {
                    out.append("0")
                    step = 2
                } else if !(at(i + 1) == "C" && at(i + 2) == "H") {
                    out.append("T")
                }
            case "V": out.append("F")
            case "W", "Y":
                if isVowel(at(i + 1)) { out.append(c) }
            case "X": out.append("KS")
            case "Z": out.append("S")
            default: out.append(c)  // F J L M N R
            }
            i += step
        }
        return String(out.prefix(maxLength))
    }

    // MARK: shared

    /// Lowercase letters of `s` with umlauts reduced to the base vowel, `ß` to `ss` and other diacritics removed.
    static func foldedLetters(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            switch ch {
            case "ß": out += "ss"
            default:
                let base = String(ch).folding(options: .diacriticInsensitive, locale: nil)
                for b in base where b.isLetter && b.isASCII { out.append(b) }
            }
        }
        return out
    }
}
