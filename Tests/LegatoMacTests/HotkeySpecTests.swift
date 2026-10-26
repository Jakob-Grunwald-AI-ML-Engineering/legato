import Foundation
import Testing
@testable import LegatoMac

@Suite struct ModifierKeyTests {
    @Test func virtualKeyCodes() {
        #expect(ModifierKey.rightCommand.keyCode == 54)
        #expect(ModifierKey.leftCommand.keyCode == 55)
        #expect(ModifierKey.rightOption.keyCode == 61)
        #expect(ModifierKey.leftOption.keyCode == 58)
        #expect(ModifierKey.rightControl.keyCode == 62)
        #expect(ModifierKey.leftControl.keyCode == 59)
        #expect(ModifierKey.rightShift.keyCode == 60)
        #expect(ModifierKey.leftShift.keyCode == 56)
        #expect(ModifierKey.function.keyCode == 63)
    }

    @Test func lookupByKeyCodeCoversEverySide() {
        for key in ModifierKey.allCases {
            #expect(ModifierKey(keyCode: key.keyCode) == key)
        }
        #expect(ModifierKey(keyCode: 8) == nil) // "c"
    }

    @Test func flagsAreTheMacOSDeviceIndependentBits() {
        // Same bit positions as CGEventFlags / NSEvent.ModifierFlags, so adapters convert by raw value.
        #expect(ModifierFlags.shift.rawValue == 1 << 17)
        #expect(ModifierFlags.control.rawValue == 1 << 18)
        #expect(ModifierFlags.option.rawValue == 1 << 19)
        #expect(ModifierFlags.command.rawValue == 1 << 20)
        #expect(ModifierFlags.function.rawValue == 1 << 23)
        #expect(ModifierKey.rightCommand.flag == .command)
        #expect(ModifierKey.leftCommand.flag == .command)
        #expect(ModifierKey.rightOption.flag == .option)
        #expect(ModifierKey.leftControl.flag == .control)
        #expect(ModifierKey.rightShift.flag == .shift)
        #expect(ModifierKey.function.flag == .function)
    }

    @Test func displayNames() {
        #expect(ModifierKey.rightCommand.displayName == "Right ⌘")
        #expect(ModifierKey.leftCommand.displayName == "Left ⌘")
        #expect(ModifierKey.rightOption.displayName == "Right ⌥")
        #expect(ModifierKey.leftOption.displayName == "Left ⌥")
        #expect(ModifierKey.rightControl.displayName == "Right ⌃")
        #expect(ModifierKey.leftControl.displayName == "Left ⌃")
        #expect(ModifierKey.rightShift.displayName == "Right ⇧")
        #expect(ModifierKey.leftShift.displayName == "Left ⇧")
        #expect(ModifierKey.function.displayName == "fn")
    }
}

@Suite struct HotkeySpecModifierMatchingTests {
    let spec = HotkeySpec.modifier(.rightCommand)

    private func flags(_ code: UInt16, _ f: ModifierFlags) -> KeyEvent {
        KeyEvent(kind: .flagsChanged, keyCode: code, flags: f)
    }

    @Test func pressWhenItsFlagComesOn() {
        #expect(spec.triggerEvent(for: flags(54, .command)) == .pressed)
    }

    @Test func releaseWhenItsFlagGoesOff() {
        #expect(spec.triggerEvent(for: flags(54, [])) == .released)
    }

    @Test func pressStillRecognizedWithOtherModifiersHeld() {
        #expect(spec.triggerEvent(for: flags(54, [.command, .shift])) == .pressed)
    }

    @Test func sidesAreDistinguished() {
        // Left ⌘ is not the trigger; as another modifier going down it is a chord key.
        #expect(spec.triggerEvent(for: flags(55, .command)) == .otherKeyDown)
        #expect(HotkeySpec.modifier(.leftCommand).triggerEvent(for: flags(54, .command)) == .otherKeyDown)
        #expect(HotkeySpec.modifier(.leftCommand).triggerEvent(for: flags(55, .command)) == .pressed)
    }

    @Test func otherModifierGoingDownIsAChordKey() {
        #expect(spec.triggerEvent(for: flags(56, [.command, .shift])) == .otherKeyDown)
    }

    @Test func otherModifierGoingUpIsIgnored() {
        #expect(spec.triggerEvent(for: flags(56, .command)) == nil)
    }

    @Test func anyKeyDownIsAChordKey() {
        #expect(spec.triggerEvent(for: KeyEvent(kind: .keyDown, keyCode: 8, flags: .command)) == .otherKeyDown)
    }

    @Test func keyUpIsIgnored() {
        #expect(spec.triggerEvent(for: KeyEvent(kind: .keyUp, keyCode: 8, flags: .command)) == nil)
    }

    @Test func functionKey() {
        let fn = HotkeySpec.modifier(.function)
        #expect(fn.triggerEvent(for: flags(63, .function)) == .pressed)
        #expect(fn.triggerEvent(for: flags(63, [])) == .released)
    }
}

@Suite struct HotkeySpecComboMatchingTests {
    /// ⌃⇧Space
    let spec = HotkeySpec.combo(keyCode: 49, modifiers: [.control, .shift])

    private func key(_ kind: KeyEvent.Kind, _ code: UInt16, _ f: ModifierFlags) -> KeyEvent {
        KeyEvent(kind: kind, keyCode: code, flags: f)
    }

    @Test func pressOnKeyDownWithExactModifiers() {
        #expect(spec.triggerEvent(for: key(.keyDown, 49, [.control, .shift])) == .pressed)
    }

    @Test func capsLockDoesNotBreakTheMatch() {
        #expect(spec.triggerEvent(for: key(.keyDown, 49, [.control, .shift, .capsLock])) == .pressed)
    }

    @Test func wrongModifiersIsAnotherKey() {
        #expect(spec.triggerEvent(for: key(.keyDown, 49, [.control])) == .otherKeyDown)
        #expect(spec.triggerEvent(for: key(.keyDown, 49, [.control, .shift, .option])) == .otherKeyDown)
    }

    @Test func differentKeyIsAnotherKey() {
        #expect(spec.triggerEvent(for: key(.keyDown, 8, [.control, .shift])) == .otherKeyDown)
    }

    @Test func releaseOnKeyUpOfTheComboKey() {
        #expect(spec.triggerEvent(for: key(.keyUp, 49, [.control, .shift])) == .released)
        // Modifiers lifted first, then the key.
        #expect(spec.triggerEvent(for: key(.keyUp, 49, [])) == .released)
    }

    @Test func releaseWhenARequiredModifierIsLifted() {
        #expect(spec.triggerEvent(for: key(.flagsChanged, 56, [.control])) == .released)
    }

    @Test func modifiersStillHeldIsNotARelease() {
        #expect(spec.triggerEvent(for: key(.flagsChanged, 56, [.control, .shift])) == nil)
        #expect(spec.triggerEvent(for: key(.flagsChanged, 57, [.control, .shift, .capsLock])) == nil)
    }

    @Test func otherKeyUpIsIgnored() {
        #expect(spec.triggerEvent(for: key(.keyUp, 8, [.control, .shift])) == nil)
    }

    @Test func comboWithoutModifiers() {
        let f5 = HotkeySpec.combo(keyCode: 96, modifiers: [])
        #expect(f5.triggerEvent(for: key(.keyDown, 96, [])) == .pressed)
        #expect(f5.triggerEvent(for: key(.keyDown, 96, .shift)) == .otherKeyDown)
    }
}

@Suite struct HotkeySpecPresentationTests {
    @Test func modifierDisplayName() {
        #expect(HotkeySpec.modifier(.rightCommand).displayName == "Right ⌘")
    }

    @Test func comboDisplayNameUsesAppleModifierOrder() {
        #expect(HotkeySpec.combo(keyCode: 49, modifiers: [.shift, .control]).displayName == "⌃⇧Space")
        #expect(HotkeySpec.combo(keyCode: 40, modifiers: [.command, .option]).displayName == "⌥⌘K")
        #expect(HotkeySpec.combo(keyCode: 96, modifiers: []).displayName == "F5")
        #expect(HotkeySpec.combo(keyCode: 36, modifiers: [.function]).displayName == "fn↩")
    }

    @Test func unknownKeyCodeStillHasAName() {
        #expect(HotkeySpec.combo(keyCode: 200, modifiers: [.command]).displayName == "⌘Key 200")
    }

    @Test func codableRoundTrip() throws {
        for spec in [HotkeySpec.modifier(.rightCommand), .combo(keyCode: 49, modifiers: [.control, .shift])] {
            let data = try JSONEncoder().encode(spec)
            #expect(try JSONDecoder().decode(HotkeySpec.self, from: data) == spec)
        }
    }
}

@Suite struct HotkeySpecImplicitFunctionFlagTests {
    private func key(_ kind: KeyEvent.Kind, _ code: UInt16, _ f: ModifierFlags) -> KeyEvent {
        KeyEvent(kind: kind, keyCode: code, flags: f)
    }

    @Test func arrowKeysCarryFnImplicitlyAndStillMatch() {
        let spec = HotkeySpec.combo(keyCode: 126, modifiers: [.command]) // ⌘↑
        #expect(spec.triggerEvent(for: key(.keyDown, 126, [.command, .function])) == .pressed)
        #expect(spec.triggerEvent(for: key(.keyDown, 126, [.command])) == .pressed)
    }

    @Test func functionKeysCarryFnImplicitlyAndStillMatch() {
        let spec = HotkeySpec.combo(keyCode: 96, modifiers: []) // F5
        #expect(spec.triggerEvent(for: key(.keyDown, 96, [.function])) == .pressed)
    }

    @Test func fnIsStillRequiredForOrdinaryKeys() {
        let spec = HotkeySpec.combo(keyCode: 36, modifiers: [.function])
        #expect(spec.triggerEvent(for: key(.keyDown, 36, [.function])) == .pressed)
        #expect(spec.triggerEvent(for: key(.keyDown, 36, [])) == .otherKeyDown)
    }

    @Test func fnOnAnOrdinaryKeyIsNotIgnoredWhenTheSpecHasNone() {
        let spec = HotkeySpec.combo(keyCode: 0, modifiers: [.command])
        #expect(spec.triggerEvent(for: key(.keyDown, 0, [.command, .function])) == .otherKeyDown)
    }
}

@Suite struct HotkeySpecWarningTests {
    @Test func modifierKeysHaveNoWarning() {
        #expect(HotkeySpec.modifier(.rightCommand).warning == nil)
    }

    @Test func plainCharacterKeysWarn() {
        #expect(HotkeySpec.combo(keyCode: 0, modifiers: []).warning == .producesCharacter) // A
        #expect(HotkeySpec.combo(keyCode: 0, modifiers: [.shift]).warning == .producesCharacter)
        #expect(HotkeySpec.combo(keyCode: 0, modifiers: [.option]).warning == .producesCharacter) // ⌥A types å
        #expect(HotkeySpec.combo(keyCode: 49, modifiers: []).warning == .producesCharacter) // Space
        #expect(HotkeySpec.combo(keyCode: 36, modifiers: []).warning == .producesCharacter) // Return
    }

    @Test func commonSystemShortcutsWarn() {
        for code: UInt16 in [8, 9, 7, 6, 12, 13, 48, 49] { // C V X Z Q W Tab Space
            #expect(HotkeySpec.combo(keyCode: code, modifiers: [.command]).warning == .systemShortcut)
        }
    }

    @Test func safeCombosHaveNoWarning() {
        #expect(HotkeySpec.combo(keyCode: 96, modifiers: []).warning == nil) // F5
        #expect(HotkeySpec.combo(keyCode: 96, modifiers: [.shift]).warning == nil)
        #expect(HotkeySpec.combo(keyCode: 126, modifiers: []).warning == nil) // ↑
        #expect(HotkeySpec.combo(keyCode: 40, modifiers: [.command, .option]).warning == nil)
        #expect(HotkeySpec.combo(keyCode: 49, modifiers: [.control, .shift]).warning == nil)
        #expect(HotkeySpec.combo(keyCode: 8, modifiers: [.command, .shift]).warning == nil)
        #expect(HotkeySpec.combo(keyCode: 0, modifiers: [.control]).warning == nil)
    }

    @Test func everyWarningHasAMessage() {
        #expect(!HotkeySpec.Warning.producesCharacter.message.isEmpty)
        #expect(!HotkeySpec.Warning.systemShortcut.message.isEmpty)
    }
}
