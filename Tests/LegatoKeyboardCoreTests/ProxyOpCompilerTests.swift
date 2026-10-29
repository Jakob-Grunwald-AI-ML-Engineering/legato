import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoKeyboardCore

/// The text proxy in miniature: the caret moves in UTF-16 units (`adjustTextPosition`), `deleteBackward` takes
/// one Character (grapheme cluster) before it, `insert` types at it.
struct CaretProxy {
    var text: String
    var caret: Int  // UTF-16

    init(_ text: String, caret: Int? = nil) {
        self.text = text
        self.caret = caret ?? text.utf16.count
    }

    var before: String { String(decoding: Array(text.utf16)[..<caret], as: UTF16.self) }
    var after: String { String(decoding: Array(text.utf16)[caret...], as: UTF16.self) }

    mutating func run(_ calls: [ProxyCall]) {
        for call in calls {
            switch call {
            case .moveCaret(let units): caret = min(max(caret + units, 0), text.utf16.count)
            case .deleteBackward(let count):
                var head = before
                head.removeLast(min(count, head.count))
                let tail = after
                text = head + tail
                caret = head.utf16.count
            case .insert(let inserted):
                let head = before + inserted
                text = head + after
                caret = head.utf16.count
            }
        }
    }
}

/// A caret-relative queue over `text` with the caret at `caret`, and the write it issues for `steps`.
private func issue(
    _ steps: [EditStep], on text: String, caret: Int? = nil, origin: EditOrigin = .liveCleanup
) throws -> (write: FieldWrite, window: String, caret: Int) {
    var queue = FieldEditQueue(FieldSnapshot(window: text, caret: caret ?? text.utf16.count))
    queue.submit(EditTransaction(origin: origin, owner: "run", base: queue.document.version, steps: steps))
    let window = queue.document.window, before = queue.document.caret
    let issued = queue.next()
    let write = try #require(issued)
    return (write, window, before)
}

private func replace(_ location: Int, _ expect: String, with text: String) -> EditStep {
    EditStep(span: Span(location: location, length: expect.utf16.count), text: text, expect: expect)
}

@Suite struct ProxyOpCompilerTests {
    @Test func aPatchMovesToTheSpanEndDeletesInsertsAndMovesBack() throws {
        let field = "I saw teh cat."
        let (write, window, caret) = try issue([replace(6, "teh", with: "the")], on: field)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        #expect(calls == [.moveCaret(utf16: -5), .deleteBackward(3), .insert("the"), .moveCaret(utf16: 5)])
        var proxy = CaretProxy(field)
        proxy.run(calls)
        #expect(proxy.text == "I saw the cat.")
        #expect(proxy.caret == 14)
    }

    @Test func noMoveWhenTheCaretIsAlreadyAtTheSpanEnd() throws {
        // An ASR append at the caret: the caret follows the text (a cleanup insert there keeps it before).
        let (write, window, caret) = try issue([.insert(" world", at: 5)], on: "Hello", origin: .asr)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        #expect(calls == [.insert(" world")])
    }

    @Test func movesCountUTF16UnitsAndDeletesCountCharactersForAnEmojiWithASkinTone() throws {
        // 👍🏽 is one Character of four UTF-16 units.
        let field = "Hi 👍🏽 there"
        let (write, window, caret) = try issue([replace(3, "👍🏽", with: "🎉")], on: field)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        #expect(calls == [.moveCaret(utf16: -6), .deleteBackward(1), .insert("🎉"), .moveCaret(utf16: 6)])
        var proxy = CaretProxy(field)
        proxy.run(calls)
        #expect(proxy.text == "Hi 🎉 there")
        #expect(proxy.caret == "Hi 🎉 there".utf16.count)
    }

    @Test func aZWJFamilyIsOneDeleteAndEightUnitsOfMove() throws {
        // 👨‍👩‍👧: three emoji joined by two ZWJs, one Character, eight UTF-16 units. The caret sits at the start.
        let family = "👨‍👩‍👧"
        let field = "a" + family + "b"
        let (write, window, caret) = try issue([replace(1, family, with: "")], on: field, caret: 0)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        #expect(calls == [.moveCaret(utf16: 9), .deleteBackward(1), .moveCaret(utf16: -1)])
        var proxy = CaretProxy(field, caret: 0)
        proxy.run(calls)
        #expect(proxy.text == "ab")
        #expect(proxy.caret == 0)
    }

    @Test func aDecomposedAccentIsTwoUnitsButOneCharacter() throws {
        // "e\u{301}" (e + combining acute) is one Character of two units, replaced by the precomposed é (one unit).
        let field = "Cafe\u{301} ok"
        let (write, window, caret) = try issue([replace(3, "e\u{301}", with: "\u{E9}")], on: field)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        #expect(calls == [.moveCaret(utf16: -3), .deleteBackward(1), .insert("\u{E9}"), .moveCaret(utf16: 3)])
        var proxy = CaretProxy(field)
        proxy.run(calls)
        #expect(proxy.text.utf8.elementsEqual("Caf\u{E9} ok".utf8))
        #expect(proxy.caret == 7)
    }

    @Test func severalStepsRunHighestFirstAndTheCaretEndsWhereTheWriteSays() throws {
        let field = "teh cat wrld!"
        let (write, window, caret) = try issue(
            [replace(0, "teh", with: "the"), replace(8, "wrld", with: "world")], on: field)
        let calls = try #require(ProxyOpCompiler.compile(write, window: window, caret: caret))
        #expect(calls == [
            .moveCaret(utf16: -1), .deleteBackward(4), .insert("world"),
            .moveCaret(utf16: -10), .deleteBackward(3), .insert("the"),
            .moveCaret(utf16: 11),
        ])
        var proxy = CaretProxy(field)
        proxy.run(calls)
        #expect(proxy.text == "the cat world!")
        #expect(proxy.caret == write.caret)
        #expect(write.caret == 14)
    }

    @Test func aStepThatDoesNotHoldItsExpectedTextCompilesToNothing() {
        let calls = ProxyOpCompiler.compile(steps: [replace(0, "xyz", with: "abc")], caret: 3, window: "teh", from: 3)
        #expect(calls == nil)
    }

    @Test func aStepOutsideTheWindowCompilesToNothing() {
        let calls = ProxyOpCompiler.compile(steps: [replace(5, "a", with: "b")], caret: 3, window: "abc", from: 3)
        #expect(calls == nil)
    }
}
