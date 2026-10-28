import ActivityKit
import AVFAudio
import LegatoCore
import Speech

/// What dictation needs from the system. A snapshot for the onboarding UI.
struct ReadinessStatus: Equatable {
    var micGranted = false
    var micDenied = false
    var activitiesEnabled = false
    var assetsInstalled = false

    var isReady: Bool { micGranted && activitiesEnabled && assetsInstalled }
}

/// The readiness port: microphone permission, Live Activities, and the speech model.
@MainActor
final class SystemReadiness: Readiness {
    /// The live engine is a downloaded model that is installed: Apple Speech's assets are not needed then.
    var modelEngineReady = false
    /// Resource admission prepares the selected speech and cleanup resources before capture can start.
    var selectedResourcesReady = false

    func snapshot() async -> ReadinessStatus {
        let mic = AVAudioApplication.shared.recordPermission
        let assets = modelEngineReady ? true : await Self.assetsInstalled()
        var status = ReadinessStatus(
            micGranted: mic == .granted,
            micDenied: mic == .denied,
            activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            assetsInstalled: assets)
        #if DEBUG
        E2E.adjust(&status)
        #endif
        return status
    }

    func check() async -> ReadinessIssue? {
        let status = await snapshot()
        if !status.micGranted { return .micPermission }
        if !status.activitiesEnabled { return .liveActivitiesDisabled }
        if !status.assetsInstalled { return .assetsMissing }
        if !selectedResourcesReady { return .assetsMissing }
        return nil
    }

    /// Whether the on-device model for the current locale is installed. `AppleSpeechEngine` only
    /// reports this by throwing from `prepare`, so the app asks the Speech framework directly.
    private static func assetsInstalled() async -> Bool {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return false }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }
}
