import Foundation

public enum ShortcutActionSetting {
    public enum Action: String, Sendable, CaseIterable { case meeting, dictation }
    public static let key = "shortcut.action"
    public static func action(in defaults: UserDefaults) -> Action {
        defaults.string(forKey: key).flatMap(Action.init(rawValue:)) ?? .meeting
    }
}
