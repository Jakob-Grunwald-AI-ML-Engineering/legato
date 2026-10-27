import Foundation

enum StartFailure: Error { case visibility, microphone }
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

@main struct RecordingStartPolicyTests {
    @MainActor static func main() async throws {
        try await keyboardVisibilityStillStartsRecording()
        try await actionButtonVisibilityStopsBeforeRecording()
        try await activitySuccessCarriesIDAndStartsOnce()
        try await microphoneFailurePropagates()
        print("PASS: keyboard activity refusal continues recording, Action Button requires activity, success carries ID, microphone failures propagate")
    }

    @MainActor static func keyboardVisibilityStillStartsRecording() async throws {
        var events: [String] = []
        do {
            try await RecordingStartPolicy.start(trigger: "keyboard", requestActivity: {
                events.append("activity.request")
                throw StartFailure.visibility
            }, activityUnavailable: { error in
                require(error as? StartFailure == .visibility, "original activity refusal must be logged")
                events.append("activity.unavailable")
            }, startRecording: { activityID in
                require(activityID == nil, "refused activity cannot supply an ID")
                events.append("recording.start")
            })
        } catch {
            require(false, "keyboard visibility refusal must continue to recording start: \(error)")
        }
        require(events == ["activity.request", "activity.unavailable", "recording.start"], "keyboard logs refusal then starts recording exactly once")
    }

    @MainActor static func actionButtonVisibilityStopsBeforeRecording() async throws {
        var events: [String] = []
        do {
            try await RecordingStartPolicy.start(trigger: "actionButton", requestActivity: {
                events.append("activity.request")
                throw StartFailure.visibility
            }, activityUnavailable: { _ in events.append("activity.unavailable") }, startRecording: { _ in
                events.append("recording.start")
            })
            require(false, "Action Button must propagate required activity failure")
        } catch let error as StartFailure {
            require(error == .visibility, "Action Button preserves the activity refusal")
        }
        require(events == ["activity.request"], "required activity refusal stops before recording")
    }

    @MainActor static func activitySuccessCarriesIDAndStartsOnce() async throws {
        for trigger in ["keyboard", "actionButton"] {
            var events: [String] = []
            try await RecordingStartPolicy.start(trigger: trigger, requestActivity: {
                events.append("activity.request")
                return "actual-activity-id"
            }, activityUnavailable: { _ in events.append("activity.unavailable") }, startRecording: { activityID in
                require(activityID == "actual-activity-id", "recording callback receives the created activity ID")
                events.append("recording.start")
            })
            require(events == ["activity.request", "recording.start"], "successful activity starts recording exactly once")
        }
    }

    @MainActor static func microphoneFailurePropagates() async throws {
        for trigger in ["keyboard", "actionButton"] {
            var events: [String] = []
            do {
                try await RecordingStartPolicy.start(trigger: trigger, requestActivity: {
                    events.append("activity.request")
                    return "activity-to-end-on-failure"
                }, activityUnavailable: { _ in events.append("activity.unavailable") }, startRecording: { activityID in
                    require(activityID == "activity-to-end-on-failure", "host can retain activity ID for failure cleanup")
                    events.append("recording.start")
                    throw StartFailure.microphone
                })
                require(false, "microphone failure must propagate through both entry points")
            } catch let error as StartFailure {
                require(error == .microphone, "activity policy cannot swallow microphone failures")
            }
            require(events == ["activity.request", "recording.start"], "microphone failure does not retry recording or get logged as activity refusal")
        }
    }
}
