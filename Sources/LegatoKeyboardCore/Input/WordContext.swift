import Foundation

/// Words around the one being typed.
public enum WordContext {
    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }

    /// The word before the one being typed (the trailing letters of `contextBefore`, possibly none), when only
    /// spaces separate them; nil at a punctuation mark, a line break or the start of the text. Word pairs form
    /// only between neighbours, so a comma between two words means no previous word.
    public static func previousWord(beforePrefixIn contextBefore: String) -> String? {
        var chars = Substring(contextBefore)
        while let last = chars.last, isWordCharacter(last) { chars = chars.dropLast() }
        let blanks = chars.reversed().prefix { $0 == " " || $0 == "\t" }.count
        guard blanks > 0 else { return nil }
        chars = chars.dropLast(blanks)
        let word = String(chars.reversed().prefix(while: isWordCharacter).reversed())
        return word.trimmingCharacters(in: CharacterSet(charactersIn: "'’")).isEmpty ? nil : word
    }
}
