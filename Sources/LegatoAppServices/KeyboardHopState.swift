/// Presentation of an admitted keyboard hop. Progress requires an operation that can still finish.
public enum KeyboardHopState: Equatable, Sendable {
    case running, ready, preparing, failed(String)

    public static func resolve(runActive: Bool, microphoneReady: Bool, failure: String?, arming: Bool) -> Self {
        if runActive { return .running }
        if microphoneReady { return .ready }
        if let failure { return .failed(failure) }
        if arming { return .preparing }
        return .failed("Microphone activation is no longer running. Return to the keyboard and tap the microphone to try again.")
    }
}
