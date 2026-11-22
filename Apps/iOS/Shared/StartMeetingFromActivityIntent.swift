import AppIntents

/// Starts a meeting from the idle dictation activity after iOS opens Legato.
struct StartMeetingFromActivityIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start meeting"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Microphone hold") var holdID: String?

    init() {}
    init(holdID: String?) { self.holdID = holdID }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if APP_TARGET
        try await AppController.shared.startMeetingFromActivity(holdID: holdID)
        #else
        throw ToggleDictationError.appRequired
        #endif
        return .result()
    }
}
