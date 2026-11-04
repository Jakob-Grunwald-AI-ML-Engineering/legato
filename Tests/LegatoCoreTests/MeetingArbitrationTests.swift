import Testing
@testable import LegatoCore

@Suite struct MeetingArbitrationTests {
    @Test func dictationIsRefusedWhileAMeetingRecords() {
        #expect(MeetingArbitration.dictationRefusal(meetingActive: true) == "Meeting recording")
        #expect(MeetingArbitration.dictationRefusal(meetingActive: false) == nil)
    }

    @Test func aMeetingStartsOnlyWithNothingElseRecording() {
        #expect(MeetingArbitration.meetingRefusal(dictationActive: false, meetingActive: false) == nil)
        #expect(MeetingArbitration.meetingRefusal(dictationActive: true, meetingActive: false) == .dictationRunning)
        #expect(MeetingArbitration.meetingRefusal(dictationActive: false, meetingActive: true) == .alreadyRecording)
    }

    @Test func aMeetingAlreadyRecordingOutranksTheOtherReason() {
        #expect(MeetingArbitration.meetingRefusal(dictationActive: true, meetingActive: true) == .alreadyRecording)
    }

    @Test func everyRefusalHasAMessage() {
        for refusal in [MeetingStartRefusal.alreadyRecording, .dictationRunning] {
            #expect(!refusal.message.isEmpty)
        }
    }
}

@Suite struct MeetingSilenceTests {
    @Test func padsWhatTheSourceDidNotDeliver() {
        #expect(MeetingSilence.deficit(elapsed: 100, delivered: 90) == 10)
    }

    @Test func ignoresJitterAndOverdelivery() {
        #expect(MeetingSilence.deficit(elapsed: 100, delivered: 99.9) == 0)
        #expect(MeetingSilence.deficit(elapsed: 100, delivered: 101) == 0)
    }
}
