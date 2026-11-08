import Foundation
import LegatoAgent

/// When dictated text is written to the field: as it is spoken (`live`, iOS keyboard only), once per take (on
/// stop, or after a quiet pause) or line by line.
/// Stored in `UserDefaults` (the Mac app's standard defaults; the iOS App Group, so keyboard and app agree) and
/// read live by the host.
public enum DictationSendSetting {
    public enum Mode: String, CaseIterable, Sendable { case onStop, afterPause, lineByLine, live }
    public static let modeKey = "dictation.send"
    /// Which model cleans each finished sentence in `live` and `lineByLine` (`haiku`, `sonnet`).
    public static let cleanupModelKey = "dictation.cleanupModel"
    public static let pauseKey = "dictation.pause"
    public static let pauseRange: ClosedRange<Double> = 1.0...10.0
    public static let pauseStep = 1.0
    public static let defaultPause = 5.0
    public static let defaultMode = Mode.live
    public static let defaultCleanupModel = ModelChoice.haiku

    /// Clamped to the supported range and snapped to the step; unreadable values fall back to 5 s.
    public static func clampedPause(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPause }
        let snapped = (value / pauseStep).rounded() * pauseStep
        return min(pauseRange.upperBound, max(pauseRange.lowerBound, snapped))
    }
    public static func mode(in defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? defaultMode
    }
    /// Haiku or Sonnet; anything else (a stale or unknown value) is the default.
    public static func cleanupModel(in defaults: UserDefaults = .standard) -> ModelChoice {
        let stored = defaults.string(forKey: cleanupModelKey).flatMap(ModelChoice.init(settingValue:))
        return stored ?? defaultCleanupModel
    }
    public static func pause(in defaults: UserDefaults = .standard) -> Double {
        clampedPause(defaults.object(forKey: pauseKey) as? Double ?? defaultPause)
    }
}

public extension ModelChoice {
    /// The two models the cleanup setting offers.
    static let cleanupChoices: [ModelChoice] = [.haiku, .sonnet]
    /// The stored setting value (`haiku`, `sonnet`); nil for anything else.
    init?(settingValue: String) {
        switch settingValue {
        case "haiku": self = .haiku
        case "sonnet": self = .sonnet
        default: return nil
        }
    }
    var settingValue: String { self == .sonnet ? "sonnet" : "haiku" }
}
