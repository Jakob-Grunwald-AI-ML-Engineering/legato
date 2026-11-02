import Foundation

/// When dictated text is written to the field: once per take (on stop, or after a quiet pause) or line by line.
/// Stored in `UserDefaults` (the Mac app's standard defaults; the iOS App Group, so keyboard and app agree) and
/// read live by the host.
public enum DictationSendSetting {
    public enum Mode: String, CaseIterable, Sendable { case onStop, afterPause, lineByLine }
    public static let modeKey = "dictation.send"
    public static let pauseKey = "dictation.pause"
    public static let pauseRange: ClosedRange<Double> = 1.0...10.0
    public static let pauseStep = 1.0
    public static let defaultPause = 5.0
    public static let defaultMode = Mode.onStop

    /// Clamped to the supported range and snapped to the step; unreadable values fall back to 5 s.
    public static func clampedPause(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPause }
        let snapped = (value / pauseStep).rounded() * pauseStep
        return min(pauseRange.upperBound, max(pauseRange.lowerBound, snapped))
    }
    public static func mode(in defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? defaultMode
    }
    public static func pause(in defaults: UserDefaults = .standard) -> Double {
        clampedPause(defaults.object(forKey: pauseKey) as? Double ?? defaultPause)
    }
}
