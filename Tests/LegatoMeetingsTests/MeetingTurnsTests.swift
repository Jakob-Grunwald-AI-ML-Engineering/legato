import Foundation
import Testing
@testable import LegatoMeetings

@Suite struct MeetingTurnsTests {
    func seg(_ text: String, _ start: TimeInterval, _ speaker: PersonID?) -> MeetingSegment {
        MeetingSegment(text: text, start: start, end: start + 2, speaker: speaker)
    }

    @Test func consecutiveSegmentsOfOneSpeakerAreOneTurnWithTheFirstStart() {
        let turns = MeetingTurns.merge([seg("So.", 10, "P1"), seg("The plan", 12, "P1"), seg("is ready.", 16, "P1"), seg("Great.", 20, "P2")])
        #expect(turns.map(\.text) == ["So. The plan is ready.", "Great."])
        #expect(turns.map(\.start) == [10, 20])
        #expect(turns[0].end == 18)
    }

    @Test func aSpeakerReturningAfterAnotherStartsANewTurn() {
        let turns = MeetingTurns.merge([seg("A", 1, "P1"), seg("B", 3, "P2"), seg("C", 5, "P1")])
        #expect(turns.map(\.text) == ["A", "B", "C"])
    }

    @Test func aBreakBetweenTwoSegmentsEndsTheTurn() {
        let segments = [seg("Before.", 10, "P1"), seg("After.", 40, "P1")]
        #expect(MeetingTurns.merge(segments, breakingAt: [25]).map(\.text) == ["Before.", "After."])
        #expect(MeetingTurns.merge(segments, breakingAt: [50]).map(\.text) == ["Before. After."])
    }

    @Test func segmentsWithoutASpeakerStaySeparate() {
        #expect(MeetingTurns.merge([seg("One.", 1, nil), seg("Two.", 3, nil)]).count == 2)
    }

    @Test func theStoredSegmentsAreNotChangedAndOrderIsByStart() {
        let segments = [seg("later", 12, "P1"), seg("first", 10, "P1")]
        #expect(MeetingTurns.merge(segments).map(\.text) == ["first later"])
        #expect(segments.map(\.text) == ["later", "first"])
    }
}
