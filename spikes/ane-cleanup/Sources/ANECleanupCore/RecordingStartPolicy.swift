/// Keeps activity admission separate from microphone-start failures.
public enum RecordingStartPolicy {
    @MainActor public static func start(
        trigger: String,
        requestActivity: () throws -> String,
        activityUnavailable: (Error) -> Void,
        startRecording: (String?) async throws -> Void
    ) async throws {
        var activityID: String?
        do {
            activityID = try requestActivity()
        } catch {
            // The keyboard's Darwin notification cannot authorize a background Live Activity.
            guard trigger == "keyboard" else { throw error }
            activityUnavailable(error)
        }
        try await startRecording(activityID)
    }
}
