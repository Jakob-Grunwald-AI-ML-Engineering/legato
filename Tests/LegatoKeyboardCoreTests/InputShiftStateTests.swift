import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct InputShiftStateTests {
    private let t = Date(timeIntervalSince1970: 1_000)

    @Test func startsOff() {
        let s = ShiftState()
        #expect(s.mode == .off)
        #expect(!s.isUppercase)
    }

    @Test func tapGoesToOnce() {
        var s = ShiftState()
        s.tapShift(at: t)
        #expect(s.mode == .once)
        #expect(s.isUppercase)
    }

    @Test func doubleTapWithinWindowIsCapsLock() {
        var s = ShiftState()
        s.tapShift(at: t)
        s.tapShift(at: t.addingTimeInterval(0.29))
        #expect(s.mode == .capsLock)
    }

    @Test func slowSecondTapTurnsOnceOff() {
        var s = ShiftState()
        s.tapShift(at: t)
        s.tapShift(at: t.addingTimeInterval(0.31))
        #expect(s.mode == .off)
    }

    @Test func tapInCapsLockTurnsOff() {
        var s = ShiftState()
        s.tapShift(at: t)
        s.tapShift(at: t.addingTimeInterval(0.1))
        s.tapShift(at: t.addingTimeInterval(0.2))
        #expect(s.mode == .off)
    }

    @Test func typingALetterInOnceTurnsOff() {
        var s = ShiftState()
        s.tapShift(at: t)
        s.didTypeLetter()
        #expect(s.mode == .off)
    }

    @Test func typingALetterKeepsCapsLock() {
        var s = ShiftState()
        s.tapShift(at: t)
        s.tapShift(at: t.addingTimeInterval(0.1))
        s.didTypeLetter()
        #expect(s.mode == .capsLock)
    }

    @Test func autoCapitalizeTurnsOffToOnceButNeverTouchesCapsLock() {
        var s = ShiftState()
        s.applyAutoCapitalization(true)
        #expect(s.mode == .once)
        s.applyAutoCapitalization(false)
        #expect(s.mode == .off)
        s.tapShift(at: t)
        s.tapShift(at: t.addingTimeInterval(0.1))
        s.applyAutoCapitalization(false)
        #expect(s.mode == .capsLock)
    }

    @Test func tapAfterAutoCapitalizeTurnsItOffRegardlessOfEarlierTaps() {
        var s = ShiftState()
        s.tapShift(at: t)
        s.didTypeLetter()
        s.applyAutoCapitalization(true)
        s.tapShift(at: t.addingTimeInterval(0.2))   // earlier tap was not "just before" this state
        #expect(s.mode == .off)
    }
}
