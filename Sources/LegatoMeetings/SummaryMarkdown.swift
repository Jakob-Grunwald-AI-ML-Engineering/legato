import Foundation

/// The block structure of a summary as the document shows it: headings, bullets (nested), numbered and checklist
/// items, and paragraphs. Inline Markdown (bold, links) is left to the view.
public enum SummaryMarkdown {
    public enum Block: Sendable, Equatable {
        case heading(level: Int, text: String)
        case bullet(level: Int, text: String)
        case todo(checked: Bool, level: Int, text: String)
        case numbered(number: Int, level: Int, text: String)
        case paragraph(String)
    }

    public static func blocks(_ text: String) -> [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { block(String($0)) }
    }

    private static func block(_ raw: String) -> Block? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        let level = indentLevel(raw)

        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
            return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
        }
        for marker in ["- ", "* "] where line.hasPrefix(marker) {
            let rest = String(line.dropFirst(2))
            for (box, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where rest.hasPrefix(box) {
                return .todo(checked: checked, level: level, text: String(rest.dropFirst(box.count)))
            }
            return .bullet(level: level, text: rest.trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("• ") { return .bullet(level: level, text: String(line.dropFirst(2))) }

        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if (1...9).contains(digits.count), let number = Int(digits) {
            let after = line.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return .numbered(number: number, level: level, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return .paragraph(line)
    }

    /// Two spaces, or one tab, per level.
    private static func indentLevel(_ raw: String) -> Int {
        var width = 0
        for c in raw {
            if c == " " { width += 1 } else if c == "\t" { width += 2 } else { break }
        }
        return width / 2
    }
}
