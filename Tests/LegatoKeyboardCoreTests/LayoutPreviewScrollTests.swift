import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutPreviewScrollTests {
    @Test func upSendsRawOnlyFromTheBottomAndLeftMustBeHorizontal() {
        #expect(PreviewScroll.swipe(dx: 2, dy: -30, startedAtBottom: true) == .sendRaw)
        #expect(PreviewScroll.swipe(dx: 2, dy: -30, startedAtBottom: false) == nil, "scrolled up, an upward drag just scrolls")
        #expect(PreviewScroll.swipe(dx: -30, dy: 4, startedAtBottom: false) == .clear)
        #expect(PreviewScroll.swipe(dx: -30, dy: 20, startedAtBottom: true) == nil, "a diagonal drag is neither")
        #expect(PreviewScroll.swipe(dx: -10, dy: 0, startedAtBottom: true) == nil, "too short")
        #expect(PreviewScroll.swipe(dx: 30, dy: 0, startedAtBottom: true) == nil, "right is nothing")
        #expect(PreviewScroll.swipe(dx: 0, dy: 40, startedAtBottom: true) == nil, "down scrolls")
    }

    @Test func followingStopsWhenScrolledUpAndResumesAtTheBottomOrWhenIdle() {
        var follow = PreviewFollow()
        #expect(follow.follows)
        follow.scrolled(distanceFromBottom: 60)
        #expect(!follow.follows)
        follow.scrolled(distanceFromBottom: PreviewScroll.bottomTolerance)
        #expect(follow.follows)
        follow.scrolled(distanceFromBottom: 30)
        follow.idleElapsed()
        #expect(follow.follows)
    }
}
