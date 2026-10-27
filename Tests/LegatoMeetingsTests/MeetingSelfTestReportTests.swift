import Foundation
import Testing
import LegatoCore
@testable import LegatoMeetings

@Suite struct MeetingSelfTestReportTests {
    private let segments = [
        MeetingSegment(stream: .mic, text: "My secret plan", start: 0, end: 1),
        MeetingSegment(stream: .mic, text: "echo of them", start: 1, end: 2, echo: true),
        MeetingSegment(stream: .system, text: "Their confidential numbers are up", start: 2, end: 3),
    ]

    private func report(includeText: Bool, segments: [MeetingSegment]? = nil) -> MeetingSelfTestReport {
        MeetingSelfTestReport(
            seconds: 15, engine: "apple-speech", engineFallback: nil, tapStatus: "running",
            segments: segments ?? self.segments, themTapZeroRatio: 0.1, themTapBuffers: 40, includeText: includeText)
    }

    @Test func byDefaultItHoldsCountsAndNoTranscriptText() throws {
        let r = report(includeText: false)
        #expect(r.meWords == 3 && r.meChars == "My secret plan".count && r.meSegments == 1)
        #expect(r.themWords == 5 && r.themChars == "Their confidential numbers are up".count && r.themSegments == 1)
        #expect(r.meText == nil && r.themText == nil)

        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("secret") && !json.contains("confidential") && !json.contains("echo of them"))
    }

    @Test func theTextComesOnlyWithTheExplicitOption() {
        let r = report(includeText: true)
        #expect(r.meText == "My secret plan")
        #expect(r.themText == "Their confidential numbers are up")
    }

    @Test func emptyThemIsReportedAsNothingHeard() {
        let r = report(includeText: false, segments: [segments[0]])
        #expect(!r.themHeardSomething)
        #expect(r.themSegments == 0)
        #expect(r.note?.contains("them is empty") == true)
        #expect(report(includeText: false).themHeardSomething)
    }

    @Test func aRunThatCouldNotStartSaysWhy() {
        let r = MeetingSelfTestReport(seconds: 10, failure: "The meeting did not start.")
        #expect(r.note == "The meeting did not start.")
        #expect(!r.themHeardSomething)
    }
}
