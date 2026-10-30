import ActivityKit
import AVFAudio
import LegatoCore

struct ReadinessStatus: Equatable {
    var micGranted = false
    var micDenied = false
    var activitiesEnabled = false
    var isReady: Bool { micGranted && activitiesEnabled }
}

@MainActor final class SystemReadiness: Readiness {
    func snapshot() async -> ReadinessStatus {
        let permission = AVAudioApplication.shared.recordPermission
        return ReadinessStatus(micGranted: permission == .granted, micDenied: permission == .denied,
            activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled)
    }
    func check() async -> ReadinessIssue? {
        let status = await snapshot()
        if !status.micGranted { return .micPermission }
        if !status.activitiesEnabled { return .liveActivitiesDisabled }
        return nil
    }
    func checkMicrophone() async -> ReadinessIssue? { await snapshot().micGranted ? nil : .micPermission }
}
