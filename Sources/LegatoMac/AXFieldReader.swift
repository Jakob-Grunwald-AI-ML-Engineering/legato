import Foundation

/// Chromium's two text spaces of one web editor. Its value (`AXValue`, `AXNumberOfCharacters`) has a line break between
/// every two lines, but its selection, `AXStringForRange` and text markers leave out the break between two adjacent
/// non-empty block lines (a tight Markdown list in CodeMirror, `<li>` or `<p>` blocks in a contenteditable). Reading
/// `0..<count` then fails, and the selection counts fewer characters than the value. The range space is the value with
/// those line breaks taken out, so its offsets map onto the value's. Right at a hidden break one range offset stands
/// for the end of the earlier line and the start of the later one.
public struct TextSpaces: Sendable, Equatable {
    /// Per range offset: the value offsets it stands for, `low...high` (they differ only at hidden line breaks).
    private let low: [Int]
    private let high: [Int]
    /// Per value offset: the range offset.
    private let ranged: [Int]

    /// Nil unless `ranged` is `value` with only line breaks taken out.
    public init?(value: String, ranged text: String) {
        let v = Array(value.utf16), r = Array(text.utf16)
        guard r.count <= v.count else { return nil }
        var matched = [Bool](repeating: false, count: v.count)
        var i = 0
        for unit in r {
            while i < v.count, v[i] != unit {
                guard v[i] == 0x0A else { return nil }
                i += 1
            }
            guard i < v.count else { return nil }
            matched[i] = true
            i += 1
        }
        while i < v.count { guard v[i] == 0x0A else { return nil }; i += 1 }
        var ranged: [Int] = [], low = [Int](repeating: -1, count: r.count + 1), high = [Int](repeating: 0, count: r.count + 1)
        ranged.reserveCapacity(v.count + 1)
        var count = 0
        for p in 0...v.count {
            ranged.append(count)
            if low[count] < 0 { low[count] = p }
            high[count] = p
            if p < v.count, matched[p] { count += 1 }
        }
        self.low = low; self.high = high; self.ranged = ranged
    }

    public var valueLength: Int { ranged.count - 1 }
    public var rangeLength: Int { low.count - 1 }
    /// Range offset `offset` stands for more than one value offset (it sits at a hidden line break).
    public func isAmbiguous(_ offset: Int) -> Bool { low.indices.contains(offset) && low[offset] != high[offset] }
    /// The value offset of range offset `offset`: after the hidden break when `afterBreak`, else before it.
    public func value(at offset: Int, afterBreak: Bool) -> Int? {
        guard low.indices.contains(offset) else { return nil }
        return afterBreak ? high[offset] : low[offset]
    }
    /// The range offset of value offset `offset`.
    public func range(at offset: Int) -> Int? { ranged.indices.contains(offset) ? ranged[offset] : nil }
}

/// One Accessibility element's raw text reads, as the host answers them; nil when a read fails.
@MainActor public protocol AXTextElement: AnyObject {
    /// `AXValue`.
    var axValue: String? { get }
    /// `AXNumberOfCharacters`.
    var axCharacterCount: Int? { get }
    /// `AXSelectedTextRange`.
    var axSelection: UTF16Range? { get }
    /// `AXStringForRange`.
    func axString(in range: UTF16Range) -> String?
    /// The whole text in the selection's space: the string of the element's text-marker range.
    var axMarkerText: String? { get }
    /// Whether the selection's start (`end` false) or end sits after a line break the selection's space leaves out: the
    /// text from the text marker before it up to it is empty. Nil when unknown.
    func axAfterHiddenBreak(end: Bool) -> Bool?
    /// The editable elements around this one that may expose the text it does not, nearest first (Chromium:
    /// `AXEditableAncestor`, then `AXHighestEditableAncestor`), never the element itself.
    var axEditableRoots: [any AXTextElement] { get }
}

/// Reads a field's text and selection in one space through its bound element, or through its editable root when the
/// element itself exposes no readable text (a nested element of a web editor). Where the element's selection space and
/// value disagree (`TextSpaces`), it reads the value and maps the selection into it, so the text the queue sees has a
/// line break between every two lines, and caret moves across one count like any character.
@MainActor public final class AXFieldReader {
    public enum ReadError: Error { case unreadable }
    /// The bound element (the one that has focus).
    public let element: any AXTextElement
    /// Where reads go: the element, or the editable root that reads where the element does not.
    public private(set) var source: any AXTextElement

    public init(element: any AXTextElement) { self.element = element; source = element }

    /// The element's text, read in one space.
    private enum Layout {
        /// The selection, range reads and count agree.
        case direct(count: Int)
        /// The selection's space leaves line breaks out: the value is read, and offsets map through `spaces`.
        case mapped(value: String, spaces: TextSpaces)
    }

    private static func layout(_ element: any AXTextElement) -> Layout? {
        guard let count = element.axCharacterCount ?? element.axValue?.utf16.count else { return nil }
        if count == 0 || element.axString(in: UTF16Range(location: count - 1, length: 1)) != nil { return .direct(count: count) }
        guard let value = element.axValue, value.utf16.count == count, let marked = element.axMarkerText,
              let spaces = TextSpaces(value: value, ranged: marked) else { return nil }
        return .mapped(value: value, spaces: spaces)
    }

    /// The read through the current source, or, when it fails, through the first of the element and its editable roots
    /// that answers (which then becomes the source).
    private func read<T>(_ body: @MainActor (any AXTextElement) -> T?) throws -> T {
        if let value = body(source) { return value }
        let candidates = [element] + element.axEditableRoots
        for candidate in candidates where candidate !== source {
            if let value = body(candidate) { source = candidate; return value }
        }
        throw ReadError.unreadable
    }

    /// The selection in the text's space.
    public func selectedRange() throws -> UTF16Range {
        try read { element in
            guard let raw = element.axSelection, let layout = Self.layout(element) else { return nil }
            switch layout {
            case .direct: return raw
            case .mapped(_, let spaces):
                @MainActor func map(_ offset: Int, end: Bool) -> Int? {
                    let after = spaces.isAmbiguous(offset) ? element.axAfterHiddenBreak(end: end) ?? false : false
                    return spaces.value(at: offset, afterBreak: after)
                }
                guard let start = map(raw.location, end: false) else { return nil }
                guard raw.length > 0 else { return UTF16Range(location: start, length: 0) }
                guard let end = map(raw.end, end: true), end >= start else { return nil }
                return UTF16Range(location: start, length: end - start)
            }
        }
    }

    /// The text in `range` of the text's space.
    public func text(in range: UTF16Range) throws -> String {
        try read { element in
            guard let layout = Self.layout(element) else { return nil }
            switch layout {
            case .direct: return element.axString(in: range)
            case .mapped(let value, _):
                let text = value as NSString
                guard range.location >= 0, range.length >= 0, range.end <= text.length else { return nil }
                return text.substring(with: NSRange(location: range.location, length: range.length))
            }
        }
    }

    /// The text's length.
    public func textLength() throws -> Int {
        try read { element in
            switch Self.layout(element) {
            case .direct(let count): count
            case .mapped(let value, _): value.utf16.count
            case nil: nil
            }
        }
    }

    /// `range` of the text's space as the source's selection space counts it (for a selection set).
    public func selectionSpace(_ range: UTF16Range) throws -> UTF16Range {
        try read { element in
            switch Self.layout(element) {
            case .direct: return range
            case .mapped(_, let spaces):
                guard let start = spaces.range(at: range.location), let end = spaces.range(at: range.end) else { return nil }
                return UTF16Range(location: start, length: end - start)
            case nil: return nil
            }
        }
    }

    /// Whether the text reads: a selection and the whole text (or its first `cap` units).
    public func readsWhole(cap: Int = 60_000) -> Bool {
        guard let selection = try? selectedRange(), let length = try? textLength(), selection.end <= length else { return false }
        return (try? text(in: UTF16Range(location: 0, length: min(length, cap)))) != nil
    }
}
