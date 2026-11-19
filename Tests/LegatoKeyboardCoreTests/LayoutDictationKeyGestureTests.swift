import Foundation
import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutDictationKeyGestureTests {
    @Test func aSwipeNeedsTheThresholdAlongOneAxis() {
        #expect(DictationKeyGesture.swipeDistance == 20)
        #expect(DictationKeyGesture.swipe(dx: 0, dy: 20) == .down)
        #expect(DictationKeyGesture.swipe(dx: 0, dy: -20) == .up)
        #expect(DictationKeyGesture.swipe(dx: -20, dy: 0) == .left)
        #expect(DictationKeyGesture.swipe(dx: 20, dy: 0) == .right)
        #expect(DictationKeyGesture.swipe(dx: 19.9, dy: 0) == nil)
        #expect(DictationKeyGesture.swipe(dx: 0, dy: -19.9) == nil)
    }

    @Test func aDiagonalDragIsNoSwipe() {
        #expect(DictationKeyGesture.swipe(dx: 30, dy: 30) == nil)
        #expect(DictationKeyGesture.swipe(dx: 30, dy: -21) == nil)
        #expect(DictationKeyGesture.swipe(dx: 30, dy: 19) == .right)
        #expect(DictationKeyGesture.swipe(dx: -12, dy: 30) == .down)
    }

    @Test func aTouchThatStaysPutTaps() {
        var drag = DictationKeyDrag()
        #expect(drag.moved(startX: 10, startY: 10, dx: 3, dy: 2) == nil)
        #expect(drag.ended(dx: 3, dy: 2) == .tap)
    }

    @Test func aSwipeFiresOnceAndNeverAlsoTaps() {
        var drag = DictationKeyDrag()
        #expect(drag.moved(startX: 10, startY: 10, dx: -8, dy: 0) == nil)
        #expect(drag.moved(startX: 10, startY: 10, dx: -22, dy: 1) == .left)
        #expect(drag.swiped)
        #expect(drag.moved(startX: 10, startY: 10, dx: -60, dy: 2) == nil)
        // Back where it started: still no tap.
        #expect(drag.ended(dx: 0, dy: 0) == nil)
        #expect(drag.swiped, "the link acting on the same lift still sees the swipe")
        #expect(drag.moved(startX: 10, startY: 10, dx: 0, dy: 0) == nil)
        #expect(!drag.swiped, "a new touch starts clean, even from the same point")
        #expect(drag.ended(dx: 0, dy: 0) == .tap)
    }

    @Test func aWanderingTouchDoesNothing() {
        var drag = DictationKeyDrag()
        _ = drag.moved(startX: 10, startY: 10, dx: 12, dy: 12)
        #expect(drag.ended(dx: 12, dy: 12) == nil)
    }

    @Test func aNewTouchStartsOverAfterACancelledOne() {
        var drag = DictationKeyDrag()
        #expect(drag.moved(startX: 10, startY: 10, dx: 0, dy: 25) == .down)
        // iOS cancelled that touch: no end came. The next one has a new start.
        #expect(drag.moved(startX: 40, startY: 12, dx: 0, dy: -25) == .up)
        _ = drag.ended(dx: 0, dy: -25)
        #expect(drag.moved(startX: 40, startY: 12, dx: 1, dy: 1) == nil)
        #expect(drag.ended(dx: 1, dy: 1) == .tap)
    }

    @Test func theHintsShowForTheFirstUsesOnly() {
        let suite = "LayoutDictationKeyGestureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var hints = DictationKeyHints(defaults: defaults)
        #expect(hints.shows && hints.uses == 0)
        for _ in 0..<(DictationKeyHints.limit - 1) { hints.noteUse() }
        #expect(hints.shows)
        hints.noteUse()
        #expect(!hints.shows)
        hints.noteUse()
        #expect(hints.uses == DictationKeyHints.limit, "counting stops at the limit")
        // A recreated keyboard remembers.
        #expect(!DictationKeyHints(defaults: UserDefaults(suiteName: suite)!).shows)
        #expect(DictationKeyHints(defaults: nil).shows)
    }

    @Test func theDictationKeySideIsStoredAndDefaultsToRight() {
        let suite = "LayoutDictationKeyGestureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DictationKeySide.stored(in: defaults) == .right)
        DictationKeySide.store(.left, in: defaults)
        #expect(DictationKeySide.stored(in: defaults) == .left)
        defaults.set("middle", forKey: DictationKeySide.preferenceKey)
        #expect(DictationKeySide.stored(in: defaults) == .right)
    }
}
