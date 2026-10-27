import Testing
@testable import LegatoCore

@Suite struct MeetingArbitrationTests {
    @Test func dictationIsRefusedWhileAMeetingRecords() {
        #expect(MeetingArbitration.dictationRefusal(meetingActive: true) == "Meeting recording")
        #expect(MeetingArbitration.dictationRefusal(meetingActive: false) == nil)
    }

    @Test func aMeetingStartsOnlyInTheForegroundWithNothingElseRecording() {
        #expect(MeetingArbitration.meetingRefusal(inBackground: false, dictationActive: false, meetingActive: false) == nil)
        #expect(MeetingArbitration.meetingRefusal(inBackground: true, dictationActive: false, meetingActive: false) == .inBackground)
        #expect(MeetingArbitration.meetingRefusal(inBackground: false, dictationActive: true, meetingActive: false) == .dictationRunning)
        #expect(MeetingArbitration.meetingRefusal(inBackground: false, dictationActive: false, meetingActive: true) == .alreadyRecording)
    }

    @Test func aMeetingAlreadyRecordingOutranksTheOtherReasons() {
        #expect(MeetingArbitration.meetingRefusal(inBackground: true, dictationActive: true, meetingActive: true) == .alreadyRecording)
        #expect(MeetingArbitration.meetingRefusal(inBackground: true, dictationActive: true, meetingActive: false) == .inBackground)
    }

    @Test func everyRefusalHasAMessage() {
        for refusal in [MeetingStartRefusal.alreadyRecording, .inBackground, .dictationRunning] {
            #expect(!refusal.message.isEmpty)
        }
    }
}

@Suite struct MeetingInterruptionsTests {
    @Test func beganMutesOnceAndRemembersWhereTheGapStarted() {
        var i = MeetingInterruptions()
        #expect(i.began(at: 10) == true)
        #expect(i.began(at: 12) == false) // a second began inside the same gap
        #expect(i.openSince == 10)
        #expect(i.needsResume)
    }

    @Test func aSuccessfulResumeClosesTheGapAndReturnsItsRange() {
        var i = MeetingInterruptions()
        _ = i.began(at: 10)
        #expect(i.ended(shouldResume: true) == true)
        #expect(i.resumed(at: 25) == 10...25)
        #expect(i.openSince == nil && !i.needsResume)
        #expect(i.resumed(at: 30) == nil)
    }

    @Test func whenTheSystemSaysDoNotResumeTheGapStaysOpenForTheNextForeground() {
        var i = MeetingInterruptions()
        _ = i.began(at: 10)
        #expect(i.ended(shouldResume: false) == false)
        #expect(i.needsResume)
        #expect(i.shouldResumeWhenForegrounded)
        #expect(i.resumed(at: 600) == 10...600)
        #expect(!i.shouldResumeWhenForegrounded)
    }

    @Test func aFailedResumeKeepsTheGapOpen() {
        var i = MeetingInterruptions()
        _ = i.began(at: 10)
        _ = i.ended(shouldResume: true)
        i.resumeFailed()
        #expect(i.openSince == 10 && i.needsResume)
    }

    @Test func anEndWithoutABeginDoesNothing() {
        var i = MeetingInterruptions()
        #expect(i.ended(shouldResume: true) == false)
        #expect(!i.shouldResumeWhenForegrounded)
    }
}

@Suite struct MeetingSilenceTests {
    @Test func padsWhatTheMicDidNotDeliver() {
        #expect(MeetingSilence.deficit(elapsed: 100, delivered: 90) == 10)
    }

    @Test func ignoresJitterAndOverdelivery() {
        #expect(MeetingSilence.deficit(elapsed: 100, delivered: 99.9) == 0)
        #expect(MeetingSilence.deficit(elapsed: 100, delivered: 101) == 0)
    }
}
