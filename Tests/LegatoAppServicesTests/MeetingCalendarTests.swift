import Foundation
import Testing
import LegatoMeetings
@testable import LegatoAppServices

@Suite struct MeetingCalendarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, from start: TimeInterval, for length: TimeInterval = 1800, allDay: Bool = false, with people: [String] = [])
        -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + length), isAllDay: allDay, attendees: people)
    }

    @Test func anEventOnNowOrStartingWithinFiveMinutesIsPickedOthersAreNot() {
        #expect(CalendarEventChoice.pick(from: [event("On", from: -600)], at: now)?.title == "On")
        #expect(CalendarEventChoice.pick(from: [event("Soon", from: 299)], at: now)?.title == "Soon")
        #expect(CalendarEventChoice.pick(from: [event("Later", from: 301)], at: now) == nil)
        #expect(CalendarEventChoice.pick(from: [event("Over", from: -3600, for: 3600)], at: now) == nil, "ended exactly now")
        #expect(CalendarEventChoice.pick(from: [], at: now) == nil)
    }

    @Test func allDayAndUntitledEventsAreSkipped() {
        #expect(CalendarEventChoice.pick(from: [event("Holiday", from: -3600, for: 86_400, allDay: true), event("  ", from: -60)], at: now) == nil)
    }

    @Test func attendeesBeatDistanceAndThenTheClosestStartWins() {
        let alone = event("Focus", from: -10)
        let withPeople = event("Sync", from: -1200, with: ["Ada"])
        #expect(CalendarEventChoice.pick(from: [alone, withPeople], at: now)?.title == "Sync")
        let near = event("Near", from: 120), far = event("Far", from: -900)
        #expect(CalendarEventChoice.pick(from: [far, near], at: now)?.title == "Near")
        #expect(CalendarEventChoice.pick(from: [near, far], at: now)?.title == "Near", "input order does not matter")
    }
}

@Suite struct MeetingAttendeesTests {
    @Test func meetingsWithoutAttendeesDecodeEmptyAndAttendeesRoundTrip() throws {
        let old = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "title": "Old", "date": 0, "duration": 5, "state": "finished"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(Meeting.self, from: old).attendees == [])
        let meeting = Meeting(title: "Sync", date: Date(timeIntervalSince1970: 0), attendees: ["Ada", "Grace"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        #expect(try decoder.decode(Meeting.self, from: encoder.encode(meeting)).attendees == ["Ada", "Grace"])
    }
}
