import Foundation
import LegatoCore
import LegatoPostProcessing

/// Explicit system model or selected downloaded Core ML model. Legacy raw values migrate on opening settings.
public enum CleanupBackendChoice: String, CaseIterable, Sendable {
    case foundationModels
    case coreML
    public var preference: CleanupRegistry.BackendPreference {
        switch self {
        case .foundationModels: .foundationModels
        case .coreML: .coreML
        }
    }
}

/// The cleanup settings at one moment.
public struct CleanupOptions: Sendable, Equatable {
    public var enabled: Bool
    public var delivery: CleanupDelivery
    public var style: CleanupStyle
    public var emoji: MessageEmojiStyle
    public var backend: CleanupBackendChoice
    /// Inverse text normalization before the language model.
    public var itn: Bool
    /// Per-stage limit, 1 to 10 seconds.
    public var timeoutSeconds: Int

    public init(
        enabled: Bool, delivery: CleanupDelivery, style: CleanupStyle, backend: CleanupBackendChoice, itn: Bool,
        timeoutSeconds: Int, emoji: MessageEmojiStyle = .off
    ) {
        self.emoji = emoji
        self.enabled = enabled
        self.delivery = delivery
        self.style = style
        self.backend = backend
        self.itn = itn
        self.timeoutSeconds = timeoutSeconds
    }
}

/// The cleanup settings in an injected `UserDefaults` (the App Group's on the phone, the app's on the Mac).
/// Off by default; delivery Live, style Verbatim, explicit Foundation Models, ITN off (#22).
/// Core ML defaults to 8 seconds and Foundation Models to 4 unless the user chose a time limit.
public struct CleanupSettingsStore: Sendable {
    // UserDefaults is documented thread-safe but not annotated Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    private enum Key {
        static let enabled = "cleanup.enabled"
        static let delivery = "cleanup.delivery"
        static let style = "cleanup.style"
        static let emoji = "cleanup.messageEmoji"
        static let backend = "cleanup.backend"
        static let itn = "cleanup.itn"
        static let timeoutSeconds = "cleanup.timeoutSeconds"
    }

    public init(defaults: UserDefaults) {
        CleanupSelectionMigration.migrate(defaults)
        // #80 removed Hold and Clipboard: an older build's value is stored again as Live.
        if let raw = defaults.string(forKey: Key.delivery), CleanupDelivery(rawValue: raw) == nil,
           let migrated = CleanupDelivery(stored: raw) {
            defaults.set(migrated.rawValue, forKey: Key.delivery)
        }
        self.defaults = defaults
    }

    public var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// How the cleanup agent cleans a run in a field: Live (the default) or Replace.
    public var delivery: CleanupDelivery {
        get { defaults.string(forKey: Key.delivery).flatMap(CleanupDelivery.init(stored:)) ?? .live }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.delivery) }
    }

    public var style: CleanupStyle {
        get { defaults.string(forKey: Key.style).flatMap(CleanupStyle.init(rawValue:)) ?? .verbatim }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.style) }
    }

    public var emoji: MessageEmojiStyle {
        get { defaults.string(forKey: Key.emoji).flatMap(MessageEmojiStyle.init(rawValue:)) ?? .off }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.emoji) }
    }

    public var backend: CleanupBackendChoice {
        get { defaults.string(forKey: Key.backend).flatMap(CleanupBackendChoice.init(rawValue:)) ?? .coreML }
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
            if stored == 0 {
                switch backend {
                case .coreML: return 8
                case .foundationModels: return 4
                }
            }
            return min(max(stored, 1), 10)
        }
        nonmutating set { defaults.set(min(max(newValue, 1), 10), forKey: Key.timeoutSeconds) }
    }

    public var options: CleanupOptions {
        CleanupOptions(
            enabled: enabled, delivery: delivery, style: style, backend: backend, itn: itn, timeoutSeconds: timeoutSeconds, emoji: emoji)
    }
}
