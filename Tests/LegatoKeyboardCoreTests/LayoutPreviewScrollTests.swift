import Testing
@testable import LegatoKeyboardCore

@Suite struct LayoutPreviewScrollTests {
    @Test func rightSendsRawLeftClearsAndVerticalOnlyScrolls() {
        #expect(PreviewScroll.swipe(dx: 30, dy: 4) == .sendRaw)
        #expect(PreviewScroll.swipe(dx: -30, dy: 4) == .clear)
        #expect(PreviewScroll.swipe(dx: -30, dy: 20) == nil, "a diagonal drag is neither")
        #expect(PreviewScroll.swipe(dx: 10, dy: 0) == nil, "too short")
        #expect(PreviewScroll.swipe(dx: 2, dy: -40) == nil, "up scrolls")
        #expect(PreviewScroll.swipe(dx: 0, dy: 40) == nil, "down scrolls")
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
