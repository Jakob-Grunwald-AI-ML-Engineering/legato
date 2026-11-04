import Foundation
import Testing
@testable import LegatoMeetings

/// Notices are per meeting, dismissible, and gone when they stop being true. The field bug: the mic note from the
/// start of a meeting was still on the document after the meeting ended, next to unrelated ones.
@Suite struct MeetingNoticesTests {
    private let a = UUID(), b = UUID()

    @Test func aNoticeShowsOnItsOwnMeetingOnly() {
        var n = MeetingNotices()
        n.post("raw mic", kind: .live, meeting: a)
        #expect(n.notices(for: a).map(\.text) == ["raw mic"])
        #expect(n.notices(for: b).isEmpty)
        #expect(n.global.isEmpty)
    }

    @Test func aNoticeWithoutAMeetingIsGlobal() {
        var n = MeetingNotices()
        n.post("Could not start the meeting", kind: .start, meeting: nil)
        #expect(n.global.map(\.text) == ["Could not start the meeting"])
        #expect(n.notices(for: a).isEmpty)
    }

    @Test func dismissingRemovesOnlyThatNotice() throws {
        var n = MeetingNotices()
        n.post("one", kind: .live, meeting: a)
        n.post("two", kind: .live, meeting: a)
        let first = try #require(n.notices(for: a).first)
        n.dismiss(first.id)
        #expect(n.notices(for: a).map(\.text) == ["two"])
    }

    @Test func postingTheSameNoticeAgainDoesNotStackIt() {
        var n = MeetingNotices()
        n.post("raw mic", kind: .live, meeting: a)
        n.post("raw mic", kind: .live, meeting: a)
        #expect(n.notices(for: a).count == 1)
    }

    @Test func noticesKeepTheOrderTheyArrivedIn() {
        var n = MeetingNotices()
        n.post("first", kind: .live, meeting: a)
        n.post("second", kind: .action, meeting: a)
        #expect(n.notices(for: a).map(\.text) == ["first", "second"])
    }

    @Test func settingTheNotesOfAKindReplacesTheEarlierOnes() {
        var n = MeetingNotices()
        n.post("keep me", kind: .action, meeting: a)
        n.set(["post-pass failed"], kind: .processing, meeting: a)
        n.set(["summary not written"], kind: .processing, meeting: a)
        #expect(n.notices(for: a).map(\.text) == ["keep me", "summary not written"])
        n.set([], kind: .processing, meeting: a)  // the next run had nothing to report: no longer true
        #expect(n.notices(for: a).map(\.text) == ["keep me"])
    }

    @Test func whenARecordingEndsItsLiveNoticesGoAndTheRestStay() {
        var n = MeetingNotices()
        n.post("Echo and noise cancellation is not downloaded yet, so the raw microphone is used.", kind: .live, meeting: a)
        n.post("The post-pass failed", kind: .processing, meeting: a)
        n.clear(kind: .live, meeting: a)
        #expect(n.notices(for: a).map(\.text) == ["The post-pass failed"])
    }

    @Test func aNewStartClearsTheOldStartFailure() {
        var n = MeetingNotices()
        n.post("Could not start the meeting", kind: .start, meeting: nil)
        n.post("About meeting B", kind: .live, meeting: b)
        n.clear(kind: .start, meeting: nil)
        #expect(n.global.isEmpty)
        #expect(n.notices(for: b).count == 1)
    }

    @Test func removingAMeetingRemovesItsNotices() {
        var n = MeetingNotices()
        n.post("x", kind: .live, meeting: a)
        n.post("y", kind: .live, meeting: b)
        n.removeMeeting(a)
        #expect(n.notices(for: a).isEmpty)
        #expect(n.notices(for: b).count == 1)
    }

    @Test func theLatestGlobalNoticeIsWhatTheMenuShows() {
        var n = MeetingNotices()
        #expect(n.latestGlobal == nil)
        n.post("one", kind: .start, meeting: nil)
        n.post("two", kind: .action, meeting: nil)
        #expect(n.latestGlobal?.text == "two")
    }

    @Test func aNoticeThatStoppedBeingTrueCanBeTakenBackByItsText() {
        var n = MeetingNotices()
        n.post("The meeting is paused: the microphone could not restart.", kind: .live, meeting: a)
        n.post("raw mic", kind: .live, meeting: a)
        n.remove(text: "The meeting is paused: the microphone could not restart.", kind: .live, meeting: a)
        #expect(n.notices(for: a).map(\.text) == ["raw mic"])
    }
}
