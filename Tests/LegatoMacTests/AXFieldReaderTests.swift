import Foundation
import Testing
@testable import LegatoMac

/// A web editor's element as Chromium answers for it (measured in Chrome and Edge, CodeMirror and contenteditable):
/// the value has a line break between every two lines, but the selection, `AXStringForRange` and the text markers leave
/// out the break between two adjacent non-empty lines (`split`). A nested element can expose nothing (`readable` false).
@MainActor final class ChromiumElement: AXTextElement {
    var text: String
    /// The caret or selection in the value's space.
    var selection: UTF16Range
    var readable = true
    var split = true
    var roots: [ChromiumElement] = []
    init(_ text: String, caret: Int? = nil) {
        self.text = text
        selection = UTF16Range(location: caret ?? text.utf16.count, length: 0)
    }

    private var units: [unichar] { Array(text.utf16) }
    /// A line break between two non-empty lines: the selection's space leaves it out.
    private func hidden(_ index: Int) -> Bool {
        let units = units
        guard split, index > 0, index + 1 < units.count, units[index] == 0x0A else { return false }
        return units[index - 1] != 0x0A && units[index + 1] != 0x0A
    }
    private var ranged: String {
        String(utf16CodeUnits: units.enumerated().filter { !hidden($0.offset) }.map(\.element), count: units.count - (0..<units.count).filter(hidden).count)
    }
    private func ranged(_ offset: Int) -> Int { offset - (0..<offset).filter(hidden).count }

    var axValue: String? { readable ? text : nil }
    var axCharacterCount: Int? { readable ? text.utf16.count : nil }
    var axSelection: UTF16Range? {
        guard readable else { return nil }
        let start = ranged(selection.location)
        return UTF16Range(location: start, length: ranged(selection.end) - start)
    }
    func axString(in range: UTF16Range) -> String? {
        guard readable else { return nil }
        let ranged = ranged as NSString
        guard range.location >= 0, range.end <= ranged.length else { return nil }
        return ranged.substring(with: NSRange(location: range.location, length: range.length))
    }
    var axMarkerText: String? { readable ? ranged : nil }
    func axAfterHiddenBreak(end: Bool) -> Bool? {
        guard readable else { return nil }
        let offset = end ? selection.end : selection.location
        return offset > 0 && hidden(offset - 1)
    }
    var axEditableRoots: [any AXTextElement] { roots }
}

@MainActor struct AXFieldReaderTests {
    static let tight = "Plan:\n1. one\n2. two\n3. three"

    @Test func aTightListMapsTheSelectionSpaceOntoTheValue() throws {
        let spaces = try #require(TextSpaces(value: Self.tight, ranged: "Plan:1. one2. two3. three"))
        #expect(spaces.valueLength == 28 && spaces.rangeLength == 25)
        // "Plan:" ends at 5 in both; the hidden break after it makes range offset 5 stand for value 5 and 6.
        #expect(spaces.isAmbiguous(5) && !spaces.isAmbiguous(4))
        #expect(spaces.value(at: 5, afterBreak: false) == 5 && spaces.value(at: 5, afterBreak: true) == 6)
        // "2. t|wo": value 17, range 15.
        #expect(spaces.value(at: 15, afterBreak: false) == 17 && spaces.range(at: 17) == 15)
        #expect(spaces.value(at: 25, afterBreak: false) == 28 && spaces.range(at: 28) == 25)
        // Not the same text with line breaks taken out: no mapping.
        #expect(TextSpaces(value: "a\nb", ranged: "ab c") == nil)
        #expect(TextSpaces(value: "a\nb", ranged: "ax") == nil)
    }

    /// The bug: a tight Markdown list in Edge read `0..<count` as an error, so every take dropped as focusLost. Through the
    /// reader it reads as its value, and the caret at a hidden break lands on the right side of it.
    @Test func aTightListReadsWholeAndTheCaretKeepsItsLine() throws {
        let element = ChromiumElement(Self.tight)
        let reader = AXFieldReader(element: element)
        #expect(element.axString(in: UTF16Range(location: 0, length: 28)) == nil)
        #expect(try reader.textLength() == 28)
        #expect(try reader.text(in: UTF16Range(location: 0, length: 28)) == Self.tight)
        // End of "1. one" and start of "2. two" are one offset in the selection's space.
        element.selection = UTF16Range(location: 12, length: 0)
        #expect(try reader.selectedRange() == UTF16Range(location: 12, length: 0))
        element.selection = UTF16Range(location: 13, length: 0)
        #expect(try reader.selectedRange() == UTF16Range(location: 13, length: 0))
        element.selection = UTF16Range(location: 17, length: 3)
        #expect(try reader.selectedRange() == UTF16Range(location: 17, length: 3))
        #expect(try reader.selectionSpace(UTF16Range(location: 17, length: 3)) == UTF16Range(location: 15, length: 2))
        #expect(reader.readsWhole())
    }

    /// Lines with an empty line between them keep their break in both spaces: read as they are.
    @Test func aLooseListReadsDirectly() throws {
        let element = ChromiumElement("Plan:\n\n1. one\n\n2. two", caret: 9)
        let reader = AXFieldReader(element: element)
        #expect(try reader.selectedRange() == UTF16Range(location: 9, length: 0))
        #expect(try reader.text(in: UTF16Range(location: 0, length: 21)) == "Plan:\n\n1. one\n\n2. two")
    }

    /// Pinned: focus sits in an element that exposes nothing; its editable root reads, so everything goes through the root.
    @Test func anUnreadableFocusedElementReadsThroughItsEditableRoot() throws {
        let root = ChromiumElement(Self.tight, caret: 20)
        let nested = ChromiumElement("")
        nested.readable = false
        nested.roots = [root]
        let reader = AXFieldReader(element: nested)
        #expect(try reader.selectedRange() == UTF16Range(location: 20, length: 0))
        #expect(try reader.text(in: UTF16Range(location: 13, length: 7)) == "2. two\n")
        #expect(reader.source === root)
        #expect(reader.readsWhole())
    }

    /// Pinned: neither the element nor its root reads: the reader says so (the take then goes on in the panel).
    @Test func neitherElementNorRootReadingIsUnreadable() {
        let root = ChromiumElement(Self.tight)
        root.readable = false
        let nested = ChromiumElement("")
        nested.readable = false
        nested.roots = [root]
        let reader = AXFieldReader(element: nested)
        #expect(throws: AXFieldReader.ReadError.self) { try reader.selectedRange() }
        #expect(!reader.readsWhole())
    }
}
