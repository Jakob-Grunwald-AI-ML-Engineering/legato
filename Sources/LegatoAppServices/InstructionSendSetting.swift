import Foundation

/// When a pending spoken instruction goes to the writer: only on Send, or after a quiet pause.
/// Stored in `UserDefaults` beside the other composer settings, and read live by the host on every speech event.
public enum InstructionSendSetting {
    public enum Mode: String, CaseIterable, Sendable { case manual, automatic }
    public static let modeKey = "composer.instructionSend"
    public static let pauseKey = "composer.instructionPause"
    public static let pauseRange: ClosedRange<Double> = 1.0...5.0
    public static let pauseStep = 0.5
    public static let defaultPause = 2.0

    /// Clamped to the supported range and snapped to the 0.5 s step; unreadable values fall back to 2 s.
    public static func clampedPause(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPause }
        let snapped = (value / pauseStep).rounded() * pauseStep
        return min(pauseRange.upperBound, max(pauseRange.lowerBound, snapped))
    }
    public static func mode(in defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .manual
    }
    public static func pause(in defaults: UserDefaults = .standard) -> Double {
        clampedPause(defaults.object(forKey: pauseKey) as? Double ?? defaultPause)
    }
    /// Seconds of quiet before sending, or nil in manual mode.
    public static func automaticDelay(in defaults: UserDefaults = .standard) -> Double? {
        mode(in: defaults) == .automatic ? pause(in: defaults) : nil
    }
}
