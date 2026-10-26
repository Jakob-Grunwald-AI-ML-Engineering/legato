import Testing
@testable import LegatoMac

@Suite struct HotkeyRecorderTests {
    private func flags(_ code: UInt16, _ f: ModifierFlags) -> KeyEvent {
        KeyEvent(kind: .flagsChanged, keyCode: code, flags: f)
    }
    private func down(_ code: UInt16, _ f: ModifierFlags = []) -> KeyEvent {
        KeyEvent(kind: .keyDown, keyCode: code, flags: f)
    }

    // MARK: lone modifiers

    @Test func lonePressAndReleaseOfRightCommandIsCaptured() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(flags(54, .command)) == .preview("Right ⌘"))
        #expect(r.feed(flags(54, [])) == .captured(.modifier(.rightCommand)))
    }

    @Test func modifierThenKeyIsACombo() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(54, .command))
        #expect(r.feed(down(40, .command)) == .captured(.combo(keyCode: 40, modifiers: [.command])))
    }

    @Test func escapeCancels() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(down(53)) == .cancelled)
    }

    @Test func bareFunctionKeyIsCaptured() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(down(96)) == .captured(.combo(keyCode: 96, modifiers: [])))
    }

    @Test func bareLetterIsIgnored() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(down(8)) == .none)
    }

    // MARK: sides, by key code

    @Test func rightCommandWhileLeftCommandHeldIsRecordedAsRightCommandAlone() {
        // Left ⌘ down, then Right ⌘ down: both flagsChanged carry the command flag, only the key code differs.
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(55, .command))
        #expect(r.feed(flags(54, .command)) == .preview("Press a key to finish"))
        // Left ⌘ lifted, flag still on because of Right ⌘.
        #expect(r.feed(flags(55, .command)) == .none)
        // Right ⌘ lifted: every key is up now.
        #expect(r.feed(flags(54, [])) == .none)
    }

    @Test func leftCommandAloneIsLeftCommandNotRight() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(55, .command))
        #expect(r.feed(flags(55, [])) == .captured(.modifier(.leftCommand)))
    }

    @Test func rightCommandCapturedAfterLeftWasFullyReleased() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(55, .command))
        _ = r.feed(flags(54, .command)) // spoiled: two keys
        _ = r.feed(flags(55, .command)) // left up, flag stays
        _ = r.feed(flags(54, [])) // right up, flag clears
        #expect(r.feed(flags(54, .command)) == .preview("Right ⌘"))
        #expect(r.feed(flags(54, [])) == .captured(.modifier(.rightCommand)))
    }

    @Test func rightCommandReleaseWithLeftStillHeldDoesNotCaptureRight() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(55, .command)) // candidate: left
        _ = r.feed(flags(54, .command)) // right joins: spoiled
        // Right lifted while left stays down: the flag stays set; this must not capture anything.
        #expect(r.feed(flags(54, .command)) == .none)
    }

    @Test func twoDifferentModifiersSpoilTheLoneModifier() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(54, .command))
        #expect(r.feed(flags(56, [.command, .shift])) == .preview("Press a key to finish"))
        #expect(r.feed(flags(56, .command)) == .none)
        #expect(r.feed(flags(54, [])) == .none)
    }

    // MARK: implicit fn

    @Test func arrowKeyStripsTheImplicitFnFlag() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(down(126, [.command, .function])) == .captured(.combo(keyCode: 126, modifiers: [.command])))
    }

    @Test func functionKeyStripsTheImplicitFnFlag() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(down(96, [.function])) == .captured(.combo(keyCode: 96, modifiers: [])))
    }

    @Test func fnHeldOnPurposeIsKeptOnAnOrdinaryKey() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(63, .function))
        #expect(r.feed(down(36, .function)) == .captured(.combo(keyCode: 36, modifiers: [.function])))
    }

    @Test func fnPressedOnPurposeBeforeAnArrowIsKept() {
        var r = HotkeyRecorderLogic()
        _ = r.feed(flags(63, .function))
        #expect(r.feed(down(123, .function)) == .captured(.combo(keyCode: 123, modifiers: [.function])))
    }

    @Test func bareArrowKeyWithOnlyImplicitFnIsIgnored() {
        var r = HotkeyRecorderLogic()
        #expect(r.feed(down(123, .function)) == .none)
    }
}
