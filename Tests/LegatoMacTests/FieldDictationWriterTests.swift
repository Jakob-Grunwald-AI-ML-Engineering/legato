import Foundation
import Testing
import LegatoCore
@testable import LegatoMac

@MainActor private final class Scene {
    var field: FocusedField
    var fallbacks: [(text: String, secure: Bool, copyOnly: Bool)] = []
    var result = FallbackResult.copied(message: "copied", reason: .appChanged)
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
        scene.result = .copied(message: "No Accessibility", reason: .accessibilityMissing)
        scene.field = .none
        #expect(await writer.write("zwei.") == .copied(message: "No Accessibility"))
        #expect(scene.fallbacks.last?.text == " zwei.", "Pasted lines are spaced apart")
        #expect(await writer.write("drei.") == .copied(message: "No Accessibility"))
        #expect(scene.fallbacks.last?.copyOnly == true)
        #expect(scene.fallbacks.last?.text == " zwei. drei.", "Once copying, the clipboard accumulates the untyped text")
    }

    @Test func heldModifiersDoNotLatchAndTheTextIsCarriedIntoTheNextWrite() async {
        let scene = Scene(.none)
        scene.result = .copied(message: "held", reason: .modifiersHeld)
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("eins.") == .held)
        #expect(scene.fallbacks.last?.copyOnly == false)
        #expect(await writer.write("zwei.") == .held)
        #expect(scene.fallbacks.last?.copyOnly == false, "A passing reason never forbids the paste")
        #expect(scene.fallbacks.last?.text == " eins. zwei.", "The held-back line goes out ahead of the next one")
        scene.result = .pasted
        #expect(await writer.write("drei.") == .pasted)
        #expect(scene.fallbacks.last?.text == " eins. zwei. drei.", "Nothing held back is lost")
        #expect(scene.fallbacks.last?.copyOnly == false)
    }

    @Test func heldTextIsTypedAheadOfTheNextLineOnceTheFieldTakesIt() async {
        let scene = Scene(.none)
        scene.result = .copied(message: "held", reason: .modifiersHeld)
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("eins.") == .held)
        let field = FakeTextTarget("")
        scene.field = .target(field)
        #expect(await writer.write("zwei.") == .typed)
        #expect(field.string == "eins. zwei.")
        #expect(await writer.finish() == nil)
    }

    @Test func aSwitchedAppOrASecureFieldLatchesTheRestOfTheRun() async {
        for reason in [CopyReason.appChanged, .secureField, .accessibilityMissing] {
            let scene = Scene(.none)
            scene.result = .copied(message: "no", reason: reason)
            let writer = scene.writer()
            writer.begin()
            #expect(await writer.write("eins.") == .copied(message: "no"))
            #expect(await writer.write("zwei.") == .copied(message: "no"))
            #expect(scene.fallbacks.last?.copyOnly == true && scene.fallbacks.last?.text == "eins. zwei.", "\(reason)")
        }
    }

    @Test func theRunEndRetriesTheHeldTextOnceThenLeavesItOnTheClipboard() async {
        let scene = Scene(.none)
        scene.result = .copied(message: "held", reason: .modifiersHeld)
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("eins.") == .held)
        #expect(await writer.finish() == .copied(message: CopyReason.modifiersHeld.toast))
        #expect(scene.fallbacks.count == 3, "Write, one retry, then the clipboard")
        #expect(scene.fallbacks.last?.copyOnly == true && scene.fallbacks.last?.text == "eins.")
        #expect(await writer.finish() == nil, "Nothing is left to settle")
    }

    @Test func theRunEndRetrySucceedsWhenTheModifiersAreUp() async {
        let scene = Scene(.none)
        scene.result = .copied(message: "held", reason: .modifiersHeld)
        let writer = scene.writer()
        writer.begin()
        await writer.write("eins.")
        scene.result = .pasted
        #expect(await writer.finish() == .pasted)
        #expect(scene.fallbacks.count == 2 && scene.fallbacks.last?.copyOnly == false)
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
    @Test func aTakeIsTypedCharacterByCharacterIntoTheField() async {
        let field = FakeTextTarget("Hi Anna,")
        let scene = TypeScene(.target(field))
        let writer = scene.writer()
        writer.begin()
        #expect(await writer.write("Ich komme später. Bis gleich!") == .typed)
        #expect(field.string == "Hi Anna, Ich komme später. Bis gleich!")
        #expect(field.writes.map(\.text) == " Ich komme später. Bis gleich!".map { String($0) })
        #expect(scene.pauses.count == "Ich komme später. Bis gleich!".count - 1)
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
        #expect(field.string == "ei")
        #expect(scene.fallbacks.count == 1 && scene.fallbacks[0].text == "ns zwei drei vier" && scene.fallbacks[0].copyOnly)
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
        #expect(field.string == "eX", "Typing stops after the user edits between characters")
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

    // MARK: Streaming

    /// A scripted take: every poll shows the next state (the last one repeats) and runs `onPoll(index)` first.
    @MainActor private final class Take {
        var states: [DictationStreamState]
        var polls = 0
        var onPoll: (Int) -> Void = { _ in }
        init(_ states: [DictationStreamState]) { self.states = states }
        func poll() -> DictationStreamState? {
            onPoll(polls)
            defer { polls += 1 }
            return states[min(polls, states.count - 1)]
        }
    }
    private func grow(_ texts: String..., final: Bool = true) -> [DictationStreamState] {
        texts.enumerated().map { .init(text: $1, isFinal: final && $0 == texts.count - 1) }
    }
    private func streamWriter(_ scene: Scene, typewriter: Bool = true) -> FieldDictationWriter {
        FieldDictationWriter(capture: { [scene] in scene.field }, fallback: { [scene] text, secure, copyOnly in
            scene.fallbacks.append((text, secure, copyOnly)); return scene.result
        }, typewriter: { typewriter }, sleep: { _ in }, pacingClock: nil)
    }

    @Test func aStreamedTakeIsTypedAsItGrowsWithOneSeparator() async {
        let field = FakeTextTarget("Hi Anna,")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene)
        writer.begin()
        let take = Take(grow("Ich", "Ich komme", "Ich komme später, bis gleich."))
        #expect(await writer.writeStreaming(poll: take.poll) == .typed)
        #expect(field.string == "Hi Anna, Ich komme später, bis gleich.")
        #expect(field.writes.count > 3, "Paced: several writes, not one")
        #expect(field.writes.first?.text == " " && field.writes.dropFirst().first?.text == "I", "The separator is decided once, ahead of the first step")
        // The next take continues the text.
        let next = Take(grow("Danke."))
        #expect(await writer.writeStreaming(poll: next.poll) == .typed)
        #expect(field.string == "Hi Anna, Ich komme später, bis gleich. Danke.")
        #expect(scene.fallbacks.isEmpty)
    }

    @Test func withTheTypewriterOffTextLandsAtOnceAsItArrives() async {
        let field = FakeTextTarget("")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene, typewriter: false)
        writer.begin()
        let take = Take(grow("Hello brave", "Hello brave new world."))
        #expect(await writer.writeStreaming(poll: take.poll) == .typed)
        #expect(field.string == "Hello brave new world.")
        #expect(field.writes.map(\.text) == ["Hello brave", " new world."], "One write per delta")
    }

    @Test func aLongArrivalRevealsEveryCharacterIndividually() async {
        let field = FakeTextTarget("")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene)
        writer.begin()
        let long = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let take = Take(grow(long))
        #expect(await writer.writeStreaming(poll: take.poll) == .typed)
        #expect(field.string == long)
        #expect(take.polls >= long.count)
        #expect(field.writes.allSatisfy { $0.text.count == 1 })
    }

    @Test func aMovedCaretStopsTheTypingAndTheRestGoesToTheClipboard() async {
        let field = FakeTextTarget("")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene, typewriter: false)
        writer.begin()
        let take = Take(grow("First part", "First part, second part", "First part, second part, third part.") )
        take.onPoll = { if $0 == 1 { field.moveCaret(to: 0) } }
        let outcome = await writer.writeStreaming(poll: take.poll)
        #expect(outcome == .copied(message: "Typing stopped: the rest is on the clipboard. Paste with ⌘V."))
        #expect(field.string == "First part")
        #expect(scene.fallbacks.last?.text == ", second part, third part." && scene.fallbacks.last?.copyOnly == true, "The whole untyped rest, once the take is final")
    }

    @Test func aFailedTakeStaysOpenAndRetractErasesExactlyItsText() async {
        let field = FakeTextTarget("Dear Anna")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene)
        writer.begin()
        let take = Take([.init(text: "Ich komme", isFinal: false), .init(text: "Ich komme später", isFinal: false),
                         .init(text: "Ich komme später", isFinal: false, stalled: true)])
        #expect(await writer.writeStreaming(poll: take.poll) == .stalled)
        #expect(field.string == "Dear Anna Ich komme später" || field.string.hasPrefix("Dear Anna Ich"), "The partial stays")
        let typed = field.string
        #expect(typed.count > "Dear Anna ".count)
        #expect(writer.retractStreamed() == .erased)
        #expect(field.string == "Dear Anna", "The partial and its separator are gone, nothing else")
        // The writer carries on with a fresh take.
        let again = Take(grow("Danke."))
        #expect(await writer.writeStreaming(poll: again.poll) == .typed)
        #expect(field.string == "Dear Anna Danke.")
    }

    @Test func retractionWhileStreamingErasesAtOnce() async {
        let field = FakeTextTarget("Hello")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene, typewriter: false)
        writer.begin()
        let take = Take([.init(text: "partial", isFinal: false), .init(text: "partial", isFinal: true, retracted: true)])
        #expect(await writer.writeStreaming(poll: take.poll) == .erased)
        #expect(field.string == "Hello")
    }

    @Test func aFieldTheUserChangedIsNeverErased() async {
        let field = FakeTextTarget("Hello")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene, typewriter: false)
        writer.begin()
        let take = Take([.init(text: "partial text", isFinal: false, stalled: true)])
        #expect(await writer.writeStreaming(poll: take.poll) == .stalled)
        field.userTypes(" and more")
        let outcome = writer.retractStreamed()
        #expect(outcome == .copied(message: "The field changed, so the partial text was left where it is."))
        #expect(field.string == "Hello partial text and more")

        let other = FakeTextTarget("Hi")
        scene.field = .target(other)
        writer.begin()
        let again = Take([.init(text: "partial text", isFinal: false, stalled: true)])
        _ = await writer.writeStreaming(poll: again.poll)
        other.externalEdit(.init(location: 3, length: 2), with: "XX")
        #expect(writer.retractStreamed() != .erased)
        #expect(other.string == "Hi XXrtial text", "An edited partial is not ours any more")
    }

    @Test func withoutAnAccessibilityFieldTheTakeIsWrittenWholeOnceFinal() async {
        let scene = Scene(.none)
        scene.result = .pasted
        let writer = streamWriter(scene)
        writer.begin()
        let take = Take(grow("Ein", "Ein Text", "Ein Text."))
        #expect(await writer.writeStreaming(poll: take.poll) == .pasted)
        #expect(scene.fallbacks.map(\.text) == ["Ein Text."])
    }

    @Test func aNeverStartedFailedTakeHasNothingToErase() async {
        let field = FakeTextTarget("Hi")
        let scene = Scene(.target(field))
        let writer = streamWriter(scene)
        writer.begin()
        let take = Take([.init(text: "", isFinal: false, stalled: true)])
        #expect(await writer.writeStreaming(poll: take.poll) == .stalled)
        #expect(writer.retractStreamed() == .erased && field.string == "Hi")
    }
}
