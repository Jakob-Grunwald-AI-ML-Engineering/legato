import Foundation
import Testing
@testable import LegatoMeetings

/// What the document's banner says about a meeting's heavy steps. The field bug: after stopping a 47-minute meeting
/// the banner said "Improving the transcript, speakers and summary…" and "Writing the summary…" although only the
/// audio step was done and the steps were merely waiting for an idle Mac.
@Suite struct MeetingBannerTests {
    private func meeting(
        _ state: Meeting.State = .processing, steps: Set<Meeting.Step> = [.audio], failedRuns: Int = 0
    ) -> Meeting {
        Meeting(title: "Sync", date: Date(timeIntervalSince1970: 1), engineID: "x", state: state, completedSteps: steps, failedRuns: failedRuns)
    }

    private func banner(
        _ meeting: Meeting, stage: ProcessingStage?, recording: Bool = false, action: Bool = false, device: String = "Mac"
    ) -> MeetingBanner {
        MeetingBanner.make(meeting: meeting, stage: stage, recordingActive: recording, actionRunning: action, device: device)
    }

    @Test func aQueuedMeetingWaitsForIdleAndOffersProcessNow() {
        let b = banner(meeting(), stage: .queued)
        #expect(b.kind == .waitingForIdle)
        #expect(b.text == "Waiting until your Mac is idle.")
        #expect(b.offersProcessNow)
    }

    @Test func waitingNeverClaimsToImproveOrWriteTheSummary() {
        for stage in [ProcessingStage.queued] {
            let text = banner(meeting(), stage: stage).text
            #expect(!text.contains("Improving") && !text.contains("Writing the summary"))
        }
    }

    @Test func theDeviceNameIsTheCallers() {
        #expect(banner(meeting(), stage: .queued, device: "iPhone").text == "Waiting until your iPhone is idle.")
    }

    @Test func aRecordingIsNamedAsTheReasonNothingStartsAndProcessNowIsNotOffered() {
        let b = banner(meeting(), stage: .queued, recording: true)
        #expect(b.kind == .waitingForRecording)
        #expect(b.text == "A meeting is recording, so nothing is processed until it ends.")
        #expect(!b.offersProcessNow)
    }

    @Test func aRunningStepSaysWhatItDoes() {
        func b(_ step: Meeting.Step?, _ progress: Double? = nil) -> MeetingBanner {
            banner(meeting(), stage: .running(step, progress: progress))
        }
        #expect(b(.postPass).text == "Re-transcribing…")
        #expect(b(.diarize).text == "Finding speakers…")
        #expect(b(.summary).text == "Writing the summary…")
        #expect(b(.audio).text == "Preparing the audio…")
        #expect(b(nil).text == "Processing…", "the job started, no step yet")
        for step in Meeting.Step.allCases + [nil] {
            #expect(b(step).kind == .working)
            #expect(!b(step).offersProcessNow)
            #expect(b(step).progress == nil, "no progress reported: an indeterminate spinner")
        }
    }

    @Test func aStepThatReportsProgressShowsItAsAPercentage() {
        func b(_ step: Meeting.Step, _ progress: Double) -> MeetingBanner {
            banner(meeting(), stage: .running(step, progress: progress))
        }
        #expect(b(.postPass, 0.4).text == "Re-transcribing… 40%")
        #expect(b(.postPass, 0.4).progress == 0.4)
        #expect(b(.summary, 0.6).text == "Writing the summary… 60%")
        #expect(b(.diarize, 0.5).text == "Finding speakers… 50%")
    }

    @Test func progressIsKeptInsideZeroAndOne() {
        #expect(banner(meeting(), stage: .running(.postPass, progress: 1.7)).progress == 1)
        #expect(banner(meeting(), stage: .running(.postPass, progress: -0.2)).progress == 0)
        #expect(banner(meeting(), stage: .running(.postPass, progress: 1.7)).text == "Re-transcribing… 100%")
    }

    @Test func waitingHasNoProgress() {
        #expect(banner(meeting(), stage: .queued).progress == nil)
    }

    @Test func aRunningStepShowsAsRunningEvenWhileARecordingIsActive() {
        // The service cuts the job when a recording starts; until it reports `queued`, the step is what runs.
        #expect(banner(meeting(), stage: .running(.summary), recording: true).kind == .working)
    }

    @Test func noStageYetMeansWaitingUnlessAnActionIsRunning() {
        #expect(banner(meeting(), stage: nil).kind == .waitingForIdle)
        let converting = banner(meeting(steps: []), stage: nil, action: true)
        #expect(converting.kind == .working)
        #expect(converting.text == "Preparing the audio…")
    }

    @Test func aMeetingThatIsNotWaitingForAnythingHasNoBanner() {
        #expect(banner(meeting(.finished, steps: [.audio, .summary]), stage: nil).kind == .hidden)
        #expect(banner(meeting(.recording), stage: .queued).kind == .hidden)
    }

    @Test func aFinishedMeetingBeingImprovedShowsNoWaitingBannerButTheStepStillSaysSo() {
        // Improve transcript flips the state to processing first; a plain Regenerate keeps it finished.
        #expect(banner(meeting(.finished, steps: [.audio, .summary]), stage: .running(.summary)).kind == .hidden)
    }

    /// Jakob: "trigger it via a click instead of auto-triggering after the meeting." A summary asked for on a
    /// finished meeting shows its progress where the summary goes, not in the processing banner.
    @Test func aSummaryRunningOnAnyMeetingShowsItsProgressWhereTheSummaryGoes() {
        let running = MeetingBanner.summarizing(stage: .running(.summary, progress: 0.4))
        #expect(running.kind == .working)
        #expect(running.text == "Writing the summary… 40%")
        #expect(running.progress == 0.4)
        #expect(MeetingBanner.summarizing(stage: .running(.summary)).text == "Writing the summary…")
        #expect(MeetingBanner.summarizing(stage: .running(.postPass, progress: 0.4)) == .hidden, "another step")
        #expect(MeetingBanner.summarizing(stage: .queued) == .hidden)
        #expect(MeetingBanner.summarizing(stage: nil) == .hidden)
    }

    @Test func anInterruptedMeetingSaysItWasCutShort() {
        let b = banner(meeting(.interrupted, steps: []), stage: .queued)
        #expect(b.kind == .waitingForIdle)
        #expect(b.text == "This meeting was cut short. Legato finishes it when your Mac is idle.")
        #expect(b.offersProcessNow)
    }

    @Test func aMeetingWhoseStepFailedSaysItTriesAgain() {
        let b = banner(meeting(failedRuns: 1), stage: .queued)
        #expect(b.text == "A step failed. Legato tries again when your Mac is idle.")
        #expect(b.offersProcessNow)
    }

    @Test func theStageKnowsWhetherSomethingRuns() {
        #expect(ProcessingStage.running(nil).isRunning)
        #expect(ProcessingStage.running(.summary).isRunning)
        #expect(!ProcessingStage.queued.isRunning)
    }

    @Test func aReportedStartResetsProgressAndLateOrStaleReportsAreIgnored() {
        var stage = ProcessingStage.running(nil)
        stage = stage.starting(.postPass)
        #expect(stage == .running(.postPass))
        stage = stage.reporting(0.4, for: .postPass)
        #expect(stage == .running(.postPass, progress: 0.4))
        stage = stage.reporting(0.3, for: .postPass)
        #expect(stage == .running(.postPass, progress: 0.4), "a late, smaller report does not move the bar back")
        stage = stage.reporting(0.9, for: .summary)
        #expect(stage == .running(.postPass, progress: 0.4), "a report for a step that is not the running one is stale")
        stage = stage.starting(.summary)
        #expect(stage == .running(.summary), "the next step starts from nothing")
        #expect(ProcessingStage.queued.reporting(0.5, for: .summary) == .queued, "a job cut short stays waiting")
    }
}
