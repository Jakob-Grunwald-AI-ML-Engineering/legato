import Foundation

/// Where a meeting's heavy steps stand, as the services report it.
public enum ProcessingStage: Sendable, Equatable {
    /// In the scheduler's queue: waiting for an idle machine, or for a recording to end. Nothing runs.
    case queued
    /// A job is running. `step` is the step it is in (nil between steps), `progress` how far that step is, 0 to 1,
    /// when the step can tell (nil: indeterminate).
    case running(Meeting.Step?, progress: Double? = nil)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The stage when `step` begins: no progress yet.
    public func starting(_ step: Meeting.Step) -> ProcessingStage { .running(step, progress: nil) }

    /// The stage after a progress report for `step`. A report for another step, one that would move the bar back
    /// (reports can arrive late), or one for a job that is no longer running changes nothing.
    public func reporting(_ progress: Double, for step: Meeting.Step) -> ProcessingStage {
        guard case .running(let current, let before) = self, current == step else { return self }
        if let before, progress < before { return self }
        return .running(step, progress: progress)
    }
}

/// What the banner of a meeting's document says about its heavy steps, and whether it offers "Process now".
///
/// Waiting (for an idle machine, or because a meeting records) is told apart from working: the banner says
/// a step is running only while one really is.
public struct MeetingBanner: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case hidden, waitingForIdle, waitingForRecording, working }

    public var kind: Kind
    public var text: String
    /// How far the running step is, 0 to 1; nil is an indeterminate spinner (or no banner at all).
    public var progress: Double?
    public var offersProcessNow: Bool

    public static let hidden = MeetingBanner(kind: .hidden, text: "", progress: nil, offersProcessNow: false)

    /// - Parameters:
    ///   - stage: the services' report for this meeting; nil when they know nothing of it (just stopped, or recovered).
    ///   - recordingActive: a meeting is starting, recording or stopping: the scheduler starts nothing.
    ///   - actionRunning: the app is doing something to the meeting itself (the audio step right after stop).
    ///   - device: "Mac" or "iPhone".
    public static func make(
        meeting: Meeting, stage: ProcessingStage?, recordingActive: Bool, actionRunning: Bool, device: String
    ) -> MeetingBanner {
        guard meeting.state == .processing || meeting.state == .interrupted else { return .hidden }
        if case .running(let step, let progress)? = stage {
            return working(step, progress: progress)
        }
        if stage == nil, actionRunning { return working(.audio, progress: nil) }
        if recordingActive {
            return MeetingBanner(
                kind: .waitingForRecording, text: "A meeting is recording, so nothing is processed until it ends.",
                progress: nil, offersProcessNow: false)
        }
        let text =
            if meeting.state == .interrupted {
                "This meeting was cut short. Legato finishes it when your \(device) is idle."
            } else if meeting.failedRuns > 0 {
                "A step failed. Legato tries again when your \(device) is idle."
            } else {
                "Waiting until your \(device) is idle."
            }
        return MeetingBanner(kind: .waitingForIdle, text: text, progress: nil, offersProcessNow: true)
    }

    private static func working(_ step: Meeting.Step?, progress: Double?) -> MeetingBanner {
        let name =
            switch step {
            case .postPass?: "Re-transcribing…"
            case .diarize?: "Finding speakers…"
            case .summary?: "Writing the summary…"
            case .audio?: "Preparing the audio…"
            case nil: "Processing…"
            }
        let clamped = progress.map { min(1, max(0, $0)) }
        let text = clamped.map { "\(name) \(Int(($0 * 100).rounded()))%" } ?? name
        return MeetingBanner(kind: .working, text: text, progress: clamped, offersProcessNow: false)
    }
}
