import Foundation

/// Word boundaries shared by direct dictation and panel insertion. Platform adapters supply field context.
public enum FieldInsertion {
    public static func separator(before text: String, after previous: Character?) -> String {
        guard let next = text.first, !next.isWhitespace, !",.;:!?)]}%…’”".contains(next),
              let previous, !previous.isWhitespace, !"([{\"'“‘„‚«¿¡".contains(previous) else { return "" }
        return " "
    }

    public static func trailingSeparator(after text: String, before next: Character?) -> String {
        guard let next else { return "" }
        return separator(before: String(next), after: text.last)
    }

    public static func prepare(_ line: String, contextBefore: String, capitalization: AutoCapitalizationType) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }
        let space = separator(before: text, after: contextBefore.last)
        if capitalization != .none, first.isLowercase,
           AutoCapitalizer.shouldCapitalize(capitalization, context: TextContext(documentContextBeforeInput: contextBefore + space)) {
            text = first.uppercased() + text.dropFirst()
        }
        return space + text
    }
}
