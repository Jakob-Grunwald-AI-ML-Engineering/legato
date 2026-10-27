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

    private func written(_ backend: String, sections: [SectionID]?, stale: Bool = false, _ day: Double) -> MeetingStore.Summary {
        MeetingStore.Summary(sections: sections, backendID: backend, text: "t", date: Date(timeIntervalSince1970: day), isStale: stale)
    }

    @Test func theDocumentShowsTheNewestSummaryOfAnyBackend() {
        let list = [written("fm", sections: ["summary"], 2), written("claude", sections: ["decisions"], 5)]
        #expect(MeetingListLogic.shownSummary(in: list)?.backendID == "claude")
        #expect(MeetingListLogic.shownSummary(in: []) == nil)
    }

    @Test func aSummaryIsStaleWhenTheNotesOrTheTickedSectionsChangedAfterIt() {
        let fresh = written("fm", sections: ["summary", "decisions"], 1)
        #expect(MeetingListLogic.staleness(of: fresh, ticked: ["summary", "decisions"]) == nil)
        #expect(MeetingListLogic.staleness(of: fresh, ticked: ["decisions", "summary"]) == nil, "the ticks are a set")
        #expect(MeetingListLogic.staleness(of: fresh, ticked: ["summary"]) == .sections)
        #expect(MeetingListLogic.staleness(of: fresh, ticked: ["summary", "decisions", "brainstorm"]) == .sections)
        let notes = written("fm", sections: ["summary"], stale: true, 1)
        #expect(MeetingListLogic.staleness(of: notes, ticked: ["summary"]) == .notes)
        #expect(MeetingListLogic.staleness(of: notes, ticked: ["decisions"]) == .sections, "the sections say more")
        let unknown = written("fm", sections: nil, 1)
        #expect(MeetingListLogic.staleness(of: unknown, ticked: ["brainstorm"]) == nil, "nothing to compare with")
    }

    @Test func theStaleTextsSayWhatChanged() {
        #expect(MeetingListLogic.StaleReason.sections.text == "Sections changed after this summary was written.")
        #expect(MeetingListLogic.StaleReason.notes.text == "Your notes changed after this summary was written.")
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

    // MARK: Card line and signature

    private func summary(_ text: String, _ day: Double = 1, sections: [SectionID]? = ["summary"]) -> MeetingStore.Summary {
        MeetingStore.Summary(sections: sections, backendID: "fm", text: text, date: Date(timeIntervalSince1970: day), isStale: false)
    }

    @Test func withSummaryTickedTheCardLineIsTheFirstSentenceOfTheSummarySection() {
        let m = meeting("Sync", at: "2026-10-27T09:00:00Z")
        let text = "## Decisions\n- Ship it.\n\n## Summary\nThe team reviewed launch readiness. More."
        let line = MeetingListLogic.cardLine(meeting: m, ticked: ["summary", "decisions"], summaries: [summary(text)], segments: [])
        #expect(line == "The team reviewed launch readiness.")
    }

    @Test func withoutSummaryTickedTheCardLineIsTheFirstLineOfTheFirstSection() {
        let m = meeting("Sync", at: "2026-10-27T09:00:00Z")
        let text = "## Action items\n- [ ] **Sam**: send the deck. Then more.\n- [ ] Ana: book the room\n\n## Open questions\n- Budget?"
        let line = MeetingListLogic.cardLine(meeting: m, ticked: ["action-items", "open-questions"], summaries: [summary(text)], segments: [])
        #expect(line == "Sam: send the deck. Then more.")
    }

    @Test func theCardLineIsTheNewestSummarysEvenFromAnotherBackend() {
        let m = meeting("Sync", at: "2026-10-27T09:00:00Z")
        let list = [summary("## Summary\nOlder one.", 2), summary("## Summary\nThe newer one.", 9)]
        #expect(MeetingListLogic.cardLine(meeting: m, ticked: ["summary"], summaries: list, segments: []) == "The newer one.")
    }

    @Test func withoutASummaryTheCardFallsBackToTheTranscript() {
        let m = meeting("Sync", at: "2026-10-27T09:00:00Z")
        let segments = [MeetingSegment(stream: .mixed, text: "Hello there.", start: 0, end: 1)]
        #expect(MeetingListLogic.cardLine(meeting: m, ticked: ["summary"], summaries: [], segments: segments) == "Hello there.")
        #expect(MeetingListLogic.cardLine(meeting: m, ticked: ["summary"], summaries: [summary("  \n")], segments: segments) == "Hello there.")
    }

    @Test func theCardSignatureChangesWhenASummaryIsRewrittenOrTheTicksChange() {
        let m = meeting("Sync", at: "2026-10-27T09:00:00Z")
        let before = MeetingListLogic.cardSignature(meeting: m, ticked: ["summary"], summaries: [summary("old", 1)])
        #expect(before == MeetingListLogic.cardSignature(meeting: m, ticked: ["summary"], summaries: [summary("old", 1)]))
        #expect(before != MeetingListLogic.cardSignature(meeting: m, ticked: ["summary"], summaries: [summary("new text", 5)]), "Regenerate / Claude")
        #expect(before != MeetingListLogic.cardSignature(meeting: m, ticked: ["decisions"], summaries: [summary("old", 1)]), "ticks changed")
        var renamed = m
        renamed.title = "Renamed"
        #expect(before != MeetingListLogic.cardSignature(meeting: renamed, ticked: ["summary"], summaries: [summary("old", 1)]))
    }

    // MARK: Empty state

    @Test func theEmptyStateNamesWhatIsHappening() {
        func state(_ shown: Int, live: Bool = false, _ query: String = "", ready: Bool = true) -> MeetingListEmptyState {
            MeetingListLogic.emptyState(shownCount: shown, hasLive: live, query: query, searchReady: ready)
        }
        #expect(state(0) == .noMeetings)
        #expect(state(3) == .none)
        #expect(state(0, live: true) == .none)
        #expect(state(0, "budget", ready: false) == .searching, "no 'No meeting matches' flash while the search still scans")
        #expect(state(0, "budget", ready: true) == .noMatch)
        #expect(state(2, "budget", ready: true) == .none)
        #expect(state(0, live: true, "budget", ready: true) == .noMatch, "the live card hides while searching")
        #expect(state(0, "   ", ready: false) == .noMeetings, "a blank query is no search")
    }

    // MARK: Following the live transcript

    @Test func theLiveTranscriptStopsFollowingWhenTheUserScrollsUpAndResumesAtTheBottom() {
        var follow = TranscriptFollow()
        #expect(follow.follows)
        follow.scrollSettled(distanceFromBottom: 600)
        #expect(!follow.follows)
        follow.scrollSettled(distanceFromBottom: 300)
        #expect(!follow.follows)
        follow.scrollSettled(distanceFromBottom: 12)
        #expect(follow.follows)
    }
}
