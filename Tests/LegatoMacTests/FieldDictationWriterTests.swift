import Foundation
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

@MainActor private final class TypeScene {
    var field: FocusedField
    var fallbacks: [(text: String, secure: Bool, copyOnly: Bool)] = []
    var result = FallbackResult.pasted
    var pid: Int32? = 100
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var pauses: [Duration] = []
    var typewriter = true
    init(_ field: FocusedField) { self.field = field }
    func writer(onPause: @escaping @MainActor () -> Void = {}) -> FieldDictationWriter {
        FieldDictationWriter(capture: { [self] in field }, fallback: { [self] text, secure, copyOnly in
            fallbacks.append((text, secure, copyOnly)); return result
        }, typewriter: { [self] in typewriter }, sleep: { [self] in pauses.append($0); onPause() },
        pacingClock: nil, frontmostApp: { [self] in pid }, now: { [self] in clock })
    }
}

@MainActor @Suite struct FieldDictationTypewriterTests {
    @Test func aTakeIsTypedWordByWordIntoTheField() async {
        let field = FakeTextTarget("Hi Anna,")
        let scene = TypeScene(.target(field))
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("Ich komme später. Bis gleich!") == .typed)
        #expect(field.string == "Hi Anna, Ich komme später. Bis gleich!")
        #expect(field.writes.count == 6, "The separator, then one verified write per word")
        #expect(scene.pauses.count == 4 && scene.pauses.allSatisfy { $0 == TypewriterPlan.duration / 4 })
        #expect(scene.fallbacks.isEmpty)
    }

    @Test func offInsertsAtOnce() async {
        let field = FakeTextTarget("")
        let scene = TypeScene(.target(field))
        scene.typewriter = false
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("eins zwei drei") == .typed)
        #expect(field.writes.count == 1 && scene.pauses.isEmpty)
    }

    @Test func aWriterThatStopsHalfWayCopiesTheUntypedRestAndNeverTypesItElsewhere() async {
        let field = FakeTextTarget("")
        let scene = TypeScene(.target(field))
        let writer = scene.writer()
        writer.begin()
        field.failWritesAfter = 2
        let outcome = await writer.write("eins zwei drei vier")
        #expect(field.string == "eins zwei ")
        #expect(scene.fallbacks.count == 1 && scene.fallbacks[0].text == "drei vier" && scene.fallbacks[0].copyOnly)
        guard case .copied(let message) = outcome else { Issue.record("expected a copy, got \(outcome)"); return }
        #expect(message.contains("clipboard"))
    }

    @Test func theUserTypingBetweenWordsStopsTheTypewriter() async {
        let field = FakeTextTarget("")
        let scene = TypeScene(.target(field))
        var pauses = 0
        let writer = scene.writer(onPause: {
            pauses += 1
            if pauses == 1 { field.userTypes("X") }
        })
        writer.begin()
        _ = await writer.write("eins zwei drei")
        #expect(field.string.hasPrefix("eins ") && !field.string.contains("drei"))
        #expect(scene.fallbacks.count == 1 && scene.fallbacks[0].copyOnly)
    }

    @Test func aFieldThatIgnoresTheFirstWordFallsBackWithTheWholeText() async {
        let field = FakeTextTarget("")
        field.ignoreWrites = true
        let scene = TypeScene(.target(field))
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("eins zwei") == .pasted)
        #expect(scene.fallbacks.map(\.text) == ["eins zwei"])
    }

    // MARK: Spacing memory

    @Test func aNewDictationIntoAPasteOnlyAppContinuesAfterTheLastOneWithASpace() async {
        let scene = TypeScene(.none)
        let writer = scene.writer()
        writer.begin()
        _ = await writer.write("Erster Satz.")
        scene.clock += 120
        writer.begin()
        _ = await writer.write("Zweiter Satz.")
        #expect(scene.fallbacks.map(\.text) == ["Erster Satz.", " Zweiter Satz."])
    }

    @Test func noSpaceAfterTenMinutesAnotherAppOrAWhitespaceEnding() async {
        let scene = TypeScene(.none)
        let writer = scene.writer()
        writer.begin()
        _ = await writer.write("Eins.")
        scene.clock += 601
        writer.begin()
        _ = await writer.write("Zwei.")
        scene.pid = 200
        scene.clock += 5
        writer.begin()
        _ = await writer.write("Drei.")
        scene.clock += 5
        writer.begin()
        _ = await writer.write("Vier.")
        #expect(scene.fallbacks.map(\.text) == ["Eins.", "Zwei.", "Drei.", " Vier."], "Only the same app within the window")
        let breaks = TypeScene(.none)
        let other = breaks.writer()
        other.begin()
        _ = await other.write("Absatz\n")
        other.begin()
        _ = await other.write("Neu")
        #expect(breaks.fallbacks.map(\.text).last == "Neu", "The last text ended in whitespace")
    }

    @Test func punctuationAndOpeningBracketsKeepTheSeparatorRules() async {
        let scene = TypeScene(.none)
        let writer = scene.writer()
        writer.begin()
        _ = await writer.write("Wort")
        writer.begin()
        _ = await writer.write(", dann")
        scene.clock += 1
        writer.begin()
        _ = await writer.write("weiter")
        #expect(scene.fallbacks.map(\.text) == ["Wort", ", dann", " weiter"])
        let opening = TypeScene(.none)
        let w = opening.writer()
        w.begin()
        _ = await w.write("(")
        w.begin()
        _ = await w.write("klammer")
        #expect(opening.fallbacks.map(\.text) == ["(", "klammer"])
    }

    @Test func aMovedCaretCancelsTheMemory() {
        let memory = DeliveryMemory(pid: 1, time: Date(timeIntervalSince1970: 0), lastCharacter: ".", caret: 10)
        let now = Date(timeIntervalSince1970: 30)
        #expect(memory.separator(before: "Neu", pid: 1, now: now, currentCaret: 10) == " ")
        #expect(memory.separator(before: "Neu", pid: 1, now: now, currentCaret: 4) == "")
        #expect(memory.separator(before: "Neu", pid: 1, now: now, currentCaret: nil) == " ")
        #expect(memory.separator(before: "Neu", pid: nil, now: now, currentCaret: nil) == "")
    }

    @Test func aTypedFallbackAndAnInterruptedOneUpdateTheMemory() async {
        let scene = TypeScene(.none)
        scene.result = .typed
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("Getippt.") == .typed)
        writer.begin()
        _ = await writer.write("Weiter")
        #expect(scene.fallbacks.map(\.text) == ["Getippt.", " Weiter"])
        scene.result = .interrupted(remainder: "rest", message: "stopped")
        writer.begin()
        #expect(await writer.write("Weiter rest") == .copied(message: "stopped"))
    }
}
