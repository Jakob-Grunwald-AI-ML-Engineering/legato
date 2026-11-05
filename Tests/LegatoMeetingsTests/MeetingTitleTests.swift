import Testing
@testable import LegatoMeetings

@Suite struct MeetingTitleTests {
    @Test func aReplyIsReducedToOneCleanLine() {
        #expect(MeetingTitle.sanitized("\"Launch planning\"\n") == "Launch planning")
        #expect(MeetingTitle.sanitized("# **Budget review**.\nSecond line") == "Budget review")
        #expect(MeetingTitle.sanitized("„Planung“") == "Planung")
    }

    @Test func anEmptyOrAbsurdReplyIsNoTitle() {
        #expect(MeetingTitle.sanitized("  \n ") == nil)
        #expect(MeetingTitle.sanitized("\"\"") == nil)
        #expect(MeetingTitle.sanitized(String(repeating: "word ", count: 40)) == nil)
    }
}
