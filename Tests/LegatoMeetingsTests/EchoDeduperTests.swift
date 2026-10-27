import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct EchoDeduperTests {
    func seg(_ stream: TranscriptEvent.Stream, _ text: String, _ start: TimeInterval, _ end: TimeInterval) -> MeetingSegment {
        MeetingSegment(stream: stream, text: text, start: start, end: end)
    }

    @Test func micRepeatingTheSystemWordsAtTheSameTimeIsAnEcho() {
        let out = EchoDeduper.mark([
            seg(.system, "So the quarterly numbers look good", 10, 13),
            seg(.mic, "so the quarterly numbers look good", 10.5, 13.5),
        ])
        #expect(out.map(\.echo) == [false, true])
    }

    @Test func aDistinctMicSegmentIsKept() {
        let out = EchoDeduper.mark([
            seg(.system, "So the quarterly numbers look good", 10, 13),
            seg(.mic, "I disagree with that plan completely", 10.5, 13.5),
        ])
        #expect(out.map(\.echo) == [false, false])
    }

    @Test func sameWordsMoreThanTwoSecondsApartAreNotAnEcho() {
        let out = EchoDeduper.mark([
            seg(.system, "thanks for joining everyone", 10, 12),
            seg(.mic, "thanks for joining everyone", 20, 22),
        ])
        #expect(out.map(\.echo) == [false, false])
    }

    @Test func aMicSegmentJustInsideTwoSecondsIsAnEcho() {
        let out = EchoDeduper.mark([
            seg(.system, "thanks for joining everyone", 10, 12),
            seg(.mic, "thanks for joining everyone", 13.9, 15),
        ])
        #expect(out.map(\.echo) == [false, true])
    }

    @Test func overlapOfExactlyEightyPercentIsAnEcho() {
        // 4 of the mic's 5 words are on the system side.
        let out = EchoDeduper.mark([
            seg(.system, "the budget is fine", 0, 3),
            seg(.mic, "The budget, is FINE today.", 0, 3),
        ])
        #expect(out.map(\.echo) == [false, true])
    }

    @Test func overlapBelowEightyPercentIsKept() {
        // 3 of 5.
        let out = EchoDeduper.mark([
            seg(.system, "the budget is", 0, 3),
            seg(.mic, "the budget is fine today", 0, 3),
        ])
        #expect(out.map(\.echo) == [false, false])
    }

    @Test func systemSegmentsAreNeverEchoes() {
        let out = EchoDeduper.mark([
            seg(.mic, "hello there everyone", 0, 2),
            seg(.system, "hello there everyone", 0, 2),
        ])
        #expect(out.map(\.echo) == [true, false])
    }

    @Test func markingIsRecomputedNotSticky() {
        var echoed = seg(.mic, "completely different words here", 0, 2)
        echoed.echo = true
        let out = EchoDeduper.mark([seg(.system, "nothing alike at all", 0, 2), echoed])
        #expect(out.map(\.echo) == [false, false])
    }

    @Test func aMicSegmentWithNoWordsIsNotAnEcho() {
        let out = EchoDeduper.mark([seg(.system, "hello", 0, 1), seg(.mic, " ... ", 0, 1)])
        #expect(out.map(\.echo) == [false, false])
    }
}
