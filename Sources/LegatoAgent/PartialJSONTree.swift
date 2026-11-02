import Foundation
import LegatoRoom

/// Progressive parse of a JSON document that is still arriving. Completed values come through whole; the one
/// string still growing comes through as its prefix; unfinished numbers and literals are left out.
public struct PartialJSONTree: Sendable {
    public enum Step: Equatable, Sendable { case key(String), index(Int) }
    /// Root value as far as it has arrived (`.null` before the first value).
    public var value: JSONValue
    /// Path from the root to the value still growing; empty once the whole document is closed.
    public var open: [Step]
    public var complete: Bool

    /// True when `key` of the root object has arrived and nothing more will be appended to it.
    public func closed(_ key: String) -> Bool { value[key] != nil && (complete || open.first != .key(key)) }
    public func string(_ key: String) -> String? { if case .string(let s) = value[key] { return s }; return nil }
    /// A string field with `closed`: an open one is cut back to its last whole word, so text only ever grows by words.
    public func words(_ key: String) -> (text: String, closed: Bool)? {
        guard let text = string(key) else { return nil }
        let done = closed(key)
        return (done ? text : Self.wholeWords(text), done)
    }
    /// An array-of-strings field: every element, the last cut back to whole words while it is still open.
    public func strings(_ key: String) -> (items: [String], closed: Bool)? {
        guard case .array(let raw) = value[key] else { return nil }
        let done = closed(key)
        var items = raw.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
        if !done, open.count >= 2, open[0] == .key(key), case .index(let i) = open[1], i == items.count - 1 { items[i] = Self.wholeWords(items[i]) }
        return (items, done)
    }
    /// The whole-word prefix: a trailing run of non-space characters may still be extended by the next fragment.
    public static func wholeWords(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return text }
        guard let space = text.lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[...space])
    }

    public init(parsing input: String) {
        var parser = Parser(Array(input.unicodeScalars))
        let (parsed, closed) = parser.value()
        value = parsed ?? .null; complete = closed && !parser.failed; open = closed ? [] : Array(parser.open.reversed())
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0, failed = false
        /// Innermost step first; reversed by the caller.
        var open: [Step] = []
        init(_ s: [Unicode.Scalar]) { self.s = s }
        var atEnd: Bool { i >= s.count }
        mutating func skip() { while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i += 1 } }

        /// The value (nil when nothing usable has arrived) and whether it is closed.
        mutating func value() -> (JSONValue?, Bool) {
            skip()
            guard !atEnd else { return (nil, false) }
            switch s[i] {
            case "{": return object()
            case "[": return array()
            case "\"": let (t, closed) = string(); return (.string(t), closed)
            case "t": return literal("true", .bool(true))
            case "f": return literal("false", .bool(false))
            case "n": return literal("null", .null)
            default: return number()
            }
        }
        mutating func literal(_ word: String, _ v: JSONValue) -> (JSONValue?, Bool) {
            for ch in word.unicodeScalars {
                guard !atEnd else { return (nil, false) }
                guard s[i] == ch else { failed = true; return (nil, false) }
                i += 1
            }
            return (v, true)
        }
        mutating func number() -> (JSONValue?, Bool) {
            let start = i
            while i < s.count, "+-0123456789.eE".unicodeScalars.contains(s[i]) { i += 1 }
            // A number that runs to the end of the input may still gain digits.
            guard i > start else { failed = true; return (nil, false) }
            guard !atEnd else { return (nil, false) }
            guard let n = Double(String(String.UnicodeScalarView(s[start..<i]))) else { failed = true; return (nil, false) }
            return (.number(n), true)
        }
        mutating func object() -> (JSONValue?, Bool) {
            i += 1
            var fields: [String: JSONValue] = [:]
            while true {
                skip()
                guard !atEnd else { return (.object(fields), false) }
                if s[i] == "}" { i += 1; return (.object(fields), true) }
                if s[i] == "," { i += 1; continue }
                guard s[i] == "\"" else { failed = true; return (.object(fields), false) }
                let (key, keyClosed) = string()
                guard keyClosed else { return (.object(fields), false) }
                skip()
                guard !atEnd else { return (.object(fields), false) }
                guard s[i] == ":" else { failed = true; return (.object(fields), false) }
                i += 1
                let (v, closed) = value()
                if let v { fields[key] = v }
                if !closed { open.append(.key(key)); return (.object(fields), false) }
            }
        }
        mutating func array() -> (JSONValue?, Bool) {
            i += 1
            var items: [JSONValue] = []
            while true {
                skip()
                guard !atEnd else { return (.array(items), false) }
                if s[i] == "]" { i += 1; return (.array(items), true) }
                if s[i] == "," { i += 1; continue }
                let (v, closed) = value()
                if let v { items.append(v) }
                if !closed { open.append(.index(items.count - (v == nil ? 0 : 1))); return (.array(items), false) }
            }
        }
        /// Decoded text and whether the closing quote arrived. An unfinished escape (`\`, `\u12`) or a high
        /// surrogate still waiting for its pair is held back, so a fragment boundary never corrupts the text.
        mutating func string() -> (String, Bool) {
            i += 1
            var out = String.UnicodeScalarView()
            func hex(_ at: Int) -> UInt32? {
                guard at + 4 <= s.count else { return nil }
                return UInt32(String(String.UnicodeScalarView(s[at..<(at + 4)])), radix: 16)
            }
            while i < s.count {
                let c = s[i]
                if c == "\"" { i += 1; return (String(out), true) }
                guard c == "\\" else { out.append(c); i += 1; continue }
                guard i + 1 < s.count else { break }
                switch s[i + 1] {
                case "n": out.append("\n"); i += 2
                case "t": out.append("\t"); i += 2
                case "r": out.append("\r"); i += 2
                case "b": out.append("\u{8}"); i += 2
                case "f": out.append("\u{c}"); i += 2
                case "u":
                    guard let unit = hex(i + 2) else {
                        // Complete but malformed hex is replaced; a short tail is simply not here yet.
                        if i + 6 <= s.count { out.append("\u{FFFD}"); i += 6; continue }
                        return (String(out), false)
                    }
                    if (0xD800..<0xDC00).contains(unit) {
                        // Wait for the whole low half: `\uDC00` needs six more scalars after the high one.
                        guard i + 12 <= s.count else {
                            if i + 6 < s.count, s[i + 6] != "\\" || (i + 7 < s.count && s[i + 7] != "u") { out.append("\u{FFFD}"); i += 6; continue }
                            return (String(out), false)
                        }
                        if s[i + 6] == "\\", s[i + 7] == "u", let low = hex(i + 8), (0xDC00..<0xE000).contains(low),
                           let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) {
                            out.append(scalar); i += 12
                        } else { out.append("\u{FFFD}"); i += 6 }
                    } else {
                        out.append(Unicode.Scalar(unit) ?? "\u{FFFD}"); i += 6
                    }
                default: out.append(s[i + 1]); i += 2   // \" \\ \/ and anything else stand for themselves
                }
            }
            return (String(out), false)
        }
    }
}
