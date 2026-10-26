import Foundation
import LegatoCore
import LegatoMLX
import LegatoPostProcessing

/// Which backend cleanup uses. Stored as its raw value.
public enum CleanupBackendChoice: String, CaseIterable, Sendable {
    /// The picked MLX model while the GPU is usable, else Apple Foundation Models.
    case auto
    /// Apple Foundation Models only.
    case foundationModels
    /// The picked MLX model (falls through to Apple Foundation Models where MLX can't run: the phone's background).
    case mlx

    public var preference: CleanupRegistry.BackendPreference { self == .foundationModels ? .foundationModels : .auto }
}

/// The cleanup settings at one moment.
public struct CleanupOptions: Sendable, Equatable {
    public var enabled: Bool
    public var delivery: CleanupDelivery
    public var style: CleanupStyle
    public var backend: CleanupBackendChoice
    /// Inverse text normalization before the language model.
    public var itn: Bool
    /// Per-stage limit, 1 to 10 seconds.
    public var timeoutSeconds: Int

    public init(
        enabled: Bool, delivery: CleanupDelivery, style: CleanupStyle, backend: CleanupBackendChoice, itn: Bool,
        timeoutSeconds: Int
    ) {
        self.enabled = enabled
        self.delivery = delivery
        self.style = style
        self.backend = backend
        self.itn = itn
        self.timeoutSeconds = timeoutSeconds
    }
}

/// The cleanup settings in an injected `UserDefaults` (the App Group's on the phone, the app's on the Mac).
/// Off by default; delivery Replace, style Verbatim, backend Auto, ITN off (#22), 4 s per stage.
public struct CleanupSettingsStore: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    private enum Key {
        static let enabled = "cleanup.enabled"
        static let delivery = "cleanup.delivery"
        static let style = "cleanup.style"
        static let backend = "cleanup.backend"
        static let itn = "cleanup.itn"
        static let timeoutSeconds = "cleanup.timeoutSeconds"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// How a cleaned text reaches a field the raw text streamed into.
    public var delivery: CleanupDelivery {
        get { defaults.string(forKey: Key.delivery).flatMap(CleanupDelivery.init(rawValue:)) ?? .replace }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.delivery) }
    }

    public var style: CleanupStyle {
        get { defaults.string(forKey: Key.style).flatMap(CleanupStyle.init(rawValue:)) ?? .verbatim }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.style) }
    }

    public var backend: CleanupBackendChoice {
        get { defaults.string(forKey: Key.backend).flatMap(CleanupBackendChoice.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    /// Default off: FluidAudio's English ITN merges "ten thirty" into "40" (#22).
    public var itn: Bool {
        get { defaults.bool(forKey: Key.itn) }
        nonmutating set { defaults.set(newValue, forKey: Key.itn) }
    }

    public var timeoutSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Key.timeoutSeconds)
            return stored == 0 ? 4 : min(max(stored, 1), 10)
        }
        nonmutating set { defaults.set(min(max(newValue, 1), 10), forKey: Key.timeoutSeconds) }
    }

    public var options: CleanupOptions {
        CleanupOptions(
            enabled: enabled, delivery: delivery, style: style, backend: backend, itn: itn, timeoutSeconds: timeoutSeconds)
    }
}
