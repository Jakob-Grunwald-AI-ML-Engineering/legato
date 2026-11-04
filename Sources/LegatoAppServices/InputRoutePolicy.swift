import Foundation

/// Which input the audio session prefers while the microphone is only held versus during a take.
/// A held mic that routes input to a Bluetooth headset keeps it in call mode and takes its stem
/// controls from the media app, so the idle hold prefers the built-in mic and a take the headset's.
///
/// Both calls are best effort: a refusal is the policy's to log, and a take never fails because of
/// one. The default does nothing (macOS, tests, release builds).
public struct InputRoutePolicy: Sendable {
    public var preferIdle: @MainActor @Sendable () async -> Void
    public var preferTake: @MainActor @Sendable () async -> Void
    public init(preferIdle: @escaping @MainActor @Sendable () async -> Void,
                preferTake: @escaping @MainActor @Sendable () async -> Void) {
        self.preferIdle = preferIdle; self.preferTake = preferTake
    }
    public static let none = InputRoutePolicy(preferIdle: {}, preferTake: {})
}
