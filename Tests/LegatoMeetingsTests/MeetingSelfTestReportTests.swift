import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingSelfTestReportTests {
    private let segments = [
        MeetingSegment(stream: .mixed, text: "My secret plan", start: 0, end: 1),
        MeetingSegment(stream: .mixed, text: "Their confidential numbers are up", start: 2, end: 3),
        MeetingSegment(stream: .mixed, text: "dup of the other", start: 3, end: 4, echo: true),
    ]

    private func report(includeText: Bool, segments: [MeetingSegment]? = nil) -> MeetingSelfTestReport {
        MeetingSelfTestReport(
            seconds: 15, engine: "apple-speech", engineFallback: nil, tapStatus: "running",
            segments: segments ?? self.segments, tapZeroRatio: 0.1, tapBuffers: 40, includeText: includeText)
    }

    @Test func byDefaultItHoldsCountsOfTheMixedTranscriptAndNoText() throws {
        let r = report(includeText: false)
        #expect(r.words == 3 + 5)
        #expect(r.chars == "My secret plan".count + "Their confidential numbers are up".count + 1)
        #expect(r.segments == 2)
        #expect(r.text == nil)

        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("secret") && !json.contains("confidential"))
    }

    @Test func theTextComesOnlyWithTheExplicitOption() {
        #expect(report(includeText: true).text == "My secret plan Their confidential numbers are up")
    }

    @Test func oldTwoStreamSegmentsStillCount() {
        let old = [
            MeetingSegment(stream: .mic, text: "one two", start: 0, end: 1),
            MeetingSegment(stream: .system, text: "three", start: 1, end: 2),
        ]
        #expect(report(includeText: false, segments: old).words == 3)
    }

    @Test func emptyTranscriptIsReportedAsNothingHeard() {
        let r = report(includeText: false, segments: [])
        #expect(!r.heardSomething)
        #expect(r.segments == 0)
        #expect(r.note?.contains("nothing was transcribed") == true)
        #expect(report(includeText: false).heardSomething)
    }

    @Test func aRunThatCouldNotStartSaysWhy() {
        let r = MeetingSelfTestReport(seconds: 10, failure: "The meeting did not start.")
        #expect(r.note == "The meeting did not start.")
        #expect(!r.heardSomething)
    }
}
