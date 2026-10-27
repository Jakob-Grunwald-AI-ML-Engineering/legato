import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingListLogicTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func meeting(_ title: String, at iso: String, speakers: [PersonID: SpeakerInfo] = [:]) -> Meeting {
        let date = ISO8601DateFormatter().date(from: iso)!
        return Meeting(title: title, date: date, engineID: "x", speakers: speakers, state: .finished)
    }

    // MARK: Day groups

    @Test func meetingsGroupByCalendarDayNewestFirst() {
        let a = meeting("a", at: "2026-10-27T09:00:00Z")
        let b = meeting("b", at: "2026-10-27T15:00:00Z")
        let c = meeting("c", at: "2026-10-26T23:30:00Z")
        let groups = MeetingListLogic.groupByDay([a, c, b], calendar: calendar)
        #expect(groups.count == 2)
        #expect(groups[0].meetings.map(\.title) == ["b", "a"])
        #expect(groups[1].meetings.map(\.title) == ["c"])
        #expect(groups[0].day > groups[1].day)
    }

    @Test func dayLabelsSayTodayAndYesterday() {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let older = calendar.date(byAdding: .day, value: -5, to: today)!
        #expect(MeetingListLogic.dayLabel(today, now: now, calendar: calendar) == "Today")
        #expect(MeetingListLogic.dayLabel(yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(MeetingListLogic.dayLabel(older, now: now, calendar: calendar) != "Today")
    }

    // MARK: One-liner

    @Test func theOneLinerIsTheFirstSentenceOfTheSummarySection() {
        let text = """
            ## Summary
            The team reviewed launch readiness. They agreed to ship on Thursday.

            ## Decisions
            - Ship.
            """
        #expect(MeetingListLogic.oneLiner(summary: text, segments: []) == "The team reviewed launch readiness.")
    }

    @Test func theOneLinerStripsBulletsAndEmphasis() {
        let text = "# Summary\n- **Sam** wants more ownership! More text.\n"
        #expect(MeetingListLogic.oneLiner(summary: text, segments: []) == "Sam wants more ownership!")
    }

    @Test func withoutASummarySectionItIsTheFirstTranscriptLine() {
        let segments = [
            MeetingSegment(stream: .mic, text: "echo", start: 0, end: 1, echo: true),
            MeetingSegment(stream: .mixed, text: "  Hello there.  ", start: 1, end: 2),
            MeetingSegment(stream: .mixed, text: "Second", start: 2, end: 3),
        ]
        #expect(MeetingListLogic.oneLiner(summary: "## Action items\n- [ ] x", segments: segments) == "Hello there.")
        #expect(MeetingListLogic.oneLiner(summary: nil, segments: segments) == "Hello there.")
        #expect(MeetingListLogic.oneLiner(summary: nil, segments: []) == "")
    }

    // MARK: Search

    @Test func searchCoversTitleSummaryNotesSpeakersAndTranscript() {
        let m = meeting("Quarterly planning", at: "2026-10-27T09:00:00Z", speakers: ["P1": SpeakerInfo(name: "Priya", colorIndex: 0)])
        let segments = [MeetingSegment(stream: .mixed, text: "the budget is fine", start: 0, end: 1)]
        func hit(_ q: String) -> Bool {
            MeetingListLogic.matches(q, meeting: m, summaries: ["Ship on Thursday"], notes: "Ask about export", segments: segments)
        }
        #expect(hit("quarterly"))
        #expect(hit("thursday"))
        #expect(hit("EXPORT"))
        #expect(hit("priya"))
        #expect(hit("budget"))
        #expect(!hit("zebra"))
    }

    @Test func everyWordOfAQueryMustMatchAndBlankMatchesAll() {
        let m = meeting("Planning", at: "2026-10-27T09:00:00Z")
        #expect(MeetingListLogic.matches("  ", meeting: m, summaries: [], notes: nil, segments: []))
        #expect(MeetingListLogic.matches("planning", meeting: m, summaries: ["budget"], notes: nil, segments: []))
        #expect(MeetingListLogic.matches("planning budget", meeting: m, summaries: ["budget"], notes: nil, segments: []))
        #expect(!MeetingListLogic.matches("planning zebra", meeting: m, summaries: ["budget"], notes: nil, segments: []))
        #expect(MeetingListLogic.matches("cafe", meeting: m, summaries: ["Café"], notes: nil, segments: []))
    }

    // MARK: Clock and stale banner

    @Test func clockShowsMinutesAndHours() {
        #expect(MeetingListLogic.clock(0) == "0:00")
        #expect(MeetingListLogic.clock(65) == "1:05")
        #expect(MeetingListLogic.clock(3725) == "1:02:05")
        #expect(MeetingListLogic.clock(-4) == "0:00")
    }

    @Test func theStaleBannerShowsOnlyForTheChosenTemplatesNewestStaleSummary() {
        func summary(_ template: String, _ backend: String, stale: Bool, _ day: Double) -> MeetingStore.Summary {
            MeetingStore.Summary(templateID: template, backendID: backend, text: "t", date: Date(timeIntervalSince1970: day), isStale: stale)
        }
        let list = [summary("summary", "a", stale: true, 3), summary("brainstorm", "a", stale: false, 2)]
        #expect(MeetingListLogic.shownSummary(in: list, templateID: "summary")?.isStale == true)
        #expect(MeetingListLogic.shownSummary(in: list, templateID: "brainstorm")?.isStale == false)
        #expect(MeetingListLogic.shownSummary(in: list, templateID: "one-on-one") == nil)
    }

    // MARK: Pill

    @Test func pillStateFollowsPauseMuteAndPhase() {
        #expect(MeetingPillState(phase: .recording, paused: false, muted: false).label == "Recording")
        #expect(MeetingPillState(phase: .recording, paused: true, muted: false).label == "Paused")
        #expect(MeetingPillState(phase: .recording, paused: false, muted: true).label == "Muted")
        #expect(MeetingPillState(phase: .starting, paused: false, muted: false).label == "Starting")
        #expect(MeetingPillState(phase: .recording, paused: true, muted: true).label == "Paused")
        #expect(!MeetingPillState(phase: .starting, paused: false, muted: false).controlsEnabled)
        #expect(MeetingPillState(phase: .recording, paused: false, muted: false).controlsEnabled)
    }
}
