import AppIntents

/// Replaces the idle dictation activity with a meeting recording.
struct StartMeetingFromActivityIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start meeting"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

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
