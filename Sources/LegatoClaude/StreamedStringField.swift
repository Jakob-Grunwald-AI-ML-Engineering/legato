import Foundation

/// Pulls the decoded value of one top-level string field out of a JSON object that arrives in chunks
/// (a tool call's `partial_json`). Other fields, in either order, are skipped. Text is handed out as soon as it is
/// decoded; an escape split across chunks (`\` / `\u00` / half a surrogate pair) is held back until complete.
public struct StreamedStringField: Sendable {
    public let key: String
    /// The value's closing quote was seen.
    public private(set) var isComplete = false
    private enum Mode { case start, seekKey, key, seekColon, seekValue, target, skip, done }
    private enum Escape { case none, slash, unicode(String) }
    private var mode = Mode.start
    private var keyText = ""
    private var keyEscaped = false
    private var matches = false
    private var escape = Escape.none
    private var highSurrogate: UInt16?
    private var depth = 0, inString = false, stringEscaped = false

    public init(key: String) { self.key = key }

    /// Feeds the next chunk; returns the text it newly decoded (possibly empty).
    public mutating func feed(_ chunk: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in chunk.unicodeScalars { consume(scalar, into: &out) }
        return String(out)
    }

    private mutating func consume(_ s: Unicode.Scalar, into out: inout String.UnicodeScalarView) {
        switch mode {
        case .start: if s == "{" { mode = .seekKey }
        case .seekKey:
            if s == "\"" { mode = .key; keyText = ""; keyEscaped = false } else if s == "}" { mode = .done }
        case .key:
            if keyEscaped { keyEscaped = false; keyText.unicodeScalars.append(s) }
            else if s == "\\" { keyEscaped = true }
            else if s == "\"" { matches = keyText == key; mode = .seekColon }
            else { keyText.unicodeScalars.append(s) }
        case .seekColon: if s == ":" { mode = .seekValue }
        case .seekValue:
            if s == " " || s == "\n" || s == "\t" || s == "\r" { return }
            if s == "\"", matches, !isComplete { mode = .target; escape = .none; return }
            mode = .skip; depth = 0; inString = false; stringEscaped = false
            consume(s, into: &out)
        case .skip:
            if inString {
                if stringEscaped { stringEscaped = false } else if s == "\\" { stringEscaped = true } else if s == "\"" { inString = false }
            } else if s == "\"" { inString = true }
            else if s == "{" || s == "[" { depth += 1 }
            else if s == "}" || s == "]" { if depth == 0 { mode = .done } else { depth -= 1 } }
            else if s == ",", depth == 0 { mode = .seekKey }
        case .target: decode(s, into: &out)
        case .done: break
        }
    }

    private mutating func decode(_ s: Unicode.Scalar, into out: inout String.UnicodeScalarView) {
        switch escape {
        case .unicode(let soFar):
            let digits = soFar + String(s)
            guard digits.unicodeScalars.count == 4 else { escape = .unicode(digits); return }
            escape = .none
            guard let unit = UInt16(digits, radix: 16) else { flushHigh(&out); out.append("\u{FFFD}"); return }
            switch unit {
            case 0xD800...0xDBFF: flushHigh(&out); highSurrogate = unit
            case 0xDC00...0xDFFF:
                if let high = highSurrogate {
                    highSurrogate = nil
                    let value = 0x10000 + (UInt32(high) - 0xD800) * 0x400 + (UInt32(unit) - 0xDC00)
                    out.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                } else { out.append("\u{FFFD}") }
            default: flushHigh(&out); out.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
            }
        case .slash:
            escape = .none
            if s == "u" { escape = .unicode(""); return }
            flushHigh(&out)
            switch s {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{C}")
            default: out.append(s)
            }
        case .none:
            if s == "\\" { escape = .slash; return } // a \u escape may still complete a pending pair
            flushHigh(&out)
            if s == "\"" { isComplete = true; mode = .skip; depth = 0; inString = false; stringEscaped = false }
            else { out.append(s) }
        }
    }

    /// A high surrogate with no low one after it decodes to U+FFFD.
    private mutating func flushHigh(_ out: inout String.UnicodeScalarView) {
        if highSurrogate != nil { highSurrogate = nil; out.append("\u{FFFD}") }
    }
}
