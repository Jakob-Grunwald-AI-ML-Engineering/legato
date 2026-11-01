import Testing
@testable import LegatoMac

@MainActor private final class Scene {
    var field: FocusedField
    var fallbacks: [(text: String, secure: Bool, copyOnly: Bool)] = []
    var result = FallbackResult.copied(message: "copied")
    init(_ field: FocusedField) { self.field = field }
    func writer() -> FieldDictationWriter {
        FieldDictationWriter(capture: { [self] in field }, fallback: { [self] text, secure, copyOnly in
            fallbacks.append((text, secure, copyOnly)); return result
        })
    }
}

@MainActor @Suite struct FieldDictationWriterTests {
    @Test func linesAreTypedInOrderWithSpacesBetween() async {
        let field = FakeTextTarget("Hi Anna,")
        let scene = Scene(.target(field))
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("Ich komme später.") == .typed)
        #expect(await writer.write("Bis gleich!") == .typed)
        #expect(field.string == "Hi Anna, Ich komme später. Bis gleich!")
        #expect(scene.fallbacks.isEmpty)
    }

    @Test func noSeparatorInAnEmptyFieldOrAfterWhitespaceOrBeforePunctuation() async {
        let empty = FakeTextTarget("")
        let scene = Scene(.target(empty))
        let writer = scene.writer()
        writer.begin()
        await writer.write("Hallo")
        await writer.write(", Welt.")
        await writer.write("\nNeue Zeile")
        #expect(empty.string == "Hallo, Welt.\nNeue Zeile")
        let spaced = FakeTextTarget("Dear ")
        scene.field = .target(spaced)
        writer.begin()
        await writer.write("Anna")
        #expect(spaced.string == "Dear Anna")
    }

    @Test func textBeforeTheCursorIsTheContext() {
        let field = FakeTextTarget("Hello world", selection: .init(location: 5, length: 0))
        let writer = Scene(.target(field)).writer()
        writer.begin()
        #expect(writer.textBeforeCursor() == "Hello")
        let long = FakeTextTarget(String(repeating: "x", count: 1000))
        let other = Scene(.target(long)).writer()
        #expect(other.textBeforeCursor().count == FieldDictationWriter.contextLimit)
        #expect(Scene(.secure).writer().textBeforeCursor().isEmpty && Scene(.none).writer().textBeforeCursor().isEmpty)
    }

    @Test func focusMovingToAnotherFieldRedirectsTheNextLine() async {
        let first = FakeTextTarget("A:")
        let second = FakeTextTarget("B:")
        let scene = Scene(.target(first))
        let writer = scene.writer()
        writer.begin()
        await writer.write("eins")
        first.focused = false
        scene.field = .target(second)
        await writer.write("zwei")
        #expect(first.string == "A: eins" && second.string == "B: zwei")
    }

    @Test func aFieldEditedBetweenLinesGetsTheNextLineAtTheCursor() async {
        let field = FakeTextTarget("")
        let scene = Scene(.target(field))
        let writer = scene.writer()
        writer.begin()
        await writer.write("eins.")
        field.externalEdit(.init(location: 0, length: 2), with: "XX")
        field.moveCaret(to: field.string.utf16.count)
        #expect(await writer.write("zwei.") == .typed)
        #expect(field.string == "XXns. zwei.")
        #expect(scene.fallbacks.isEmpty)
    }

    @Test func anIgnoredWriteFallsBackToPasteThenKeepsTheRestOfTheRunOnTheClipboard() async {
        let field = FakeTextTarget("")
        field.ignoreWrites = true
        let scene = Scene(.target(field))
        scene.result = .pasted
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("eins.") == .pasted)
        #expect(scene.fallbacks.last?.text == "eins." && scene.fallbacks.last?.copyOnly == false)
        scene.result = .copied(message: "No Accessibility")
        scene.field = .none
        #expect(await writer.write("zwei.") == .copied(message: "No Accessibility"))
        #expect(scene.fallbacks.last?.text == " zwei.", "Pasted lines are spaced apart")
        #expect(await writer.write("drei.") == .copied(message: "No Accessibility"))
        #expect(scene.fallbacks.last?.copyOnly == true)
        #expect(scene.fallbacks.last?.text == " zwei. drei.", "Once copying, the clipboard accumulates the untyped text")
    }

    @Test func aSecureFieldIsNeverTypedOrPasted() async {
        let scene = Scene(.secure)
        let writer = scene.writer()
        writer.begin()
        await writer.write("geheim")
        #expect(scene.fallbacks.count == 1 && scene.fallbacks[0].secure && scene.fallbacks[0].copyOnly)
    }

    @Test func beginForgetsTheLastRunsClipboardAndField() async {
        let scene = Scene(.none)
        let writer = scene.writer()
        writer.begin()
        await writer.write("alt")
        let field = FakeTextTarget("")
        scene.field = .target(field)
        writer.begin()
        #expect(await writer.write("neu") == .typed)
        #expect(field.string == "neu")
    }
}
