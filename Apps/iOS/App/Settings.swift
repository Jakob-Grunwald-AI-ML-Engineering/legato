import Foundation
import LegatoCore

/// The App Group, shared with the widget extension and (later) the keyboard.
enum AppGroup {
    static let id = "group.de.gruenwald.legato"

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// User settings, in the App Group's `UserDefaults`.
enum Settings {
    private enum Key {
        static let audioPolicy = "audioPolicy"
        static let restartAfterBackgroundStop = "restartAfterBackgroundStop"
        static let debugShowPauseOthers = "debugShowPauseOthers"
        static let debugForceTapToCopy = "debugForceTapToCopy"
    }

    /// How dictation shares audio with other apps. Default `.duckOthers`. A stored policy that is no
    /// longer offered (e.g. `.pauseOthers` after the debug toggle went off) falls back to the default.
    static var audioPolicy: AudioPolicy {
        get {
            let stored = AppGroup.defaults.string(forKey: Key.audioPolicy).flatMap(AudioPolicy.init(rawValue:))
            guard let stored, offeredPolicies.contains(stored) else { return .default }
            return stored
        }
        set { AppGroup.defaults.set(newValue.rawValue, forKey: Key.audioPolicy) }
    }

    /// Policies the picker offers: the package's list, plus `.pauseOthers` while the debug toggle is on.
    static var offeredPolicies: [AudioPolicy] {
        debugShowPauseOthers ? AudioPolicy.offeredPolicies + [.pauseOthers] : AudioPolicy.offeredPolicies
    }

    /// Workaround for a device finding (spikes/ios-keyboard/FINDINGS.md): a second background mic start
    /// in the same process fails while other audio plays, so the app quits (`exit(0)`) shortly after a
    /// background stop and every press is a fresh launch. Default on.
    ///
    /// Only builds with the `LEGATO_INTERNAL` compilation condition (Debug; TestFlight via
    /// `OTHER_SWIFT_FLAGS='$(inherited) -D LEGATO_INTERNAL'`) contain the setting and the `exit(0)`
    /// call. App Store builds compile both out and always read false.
    static var restartAfterBackgroundStop: Bool {
        get {
            #if LEGATO_INTERNAL
            AppGroup.defaults.object(forKey: Key.restartAfterBackgroundStop) as? Bool ?? true
            #else
            false
            #endif
        }
        set {
            #if LEGATO_INTERNAL
            AppGroup.defaults.set(newValue, forKey: Key.restartAfterBackgroundStop)
            #endif
        }
    }

    /// Debug: offer `.pauseOthers` in the audio picker (the #6 device test).
    static var debugShowPauseOthers: Bool {
        get { AppGroup.defaults.bool(forKey: Key.debugShowPauseOthers) }
        set { AppGroup.defaults.set(newValue, forKey: Key.debugShowPauseOthers) }
    }

    /// Debug: the pasteboard client reports "didn't change", so the activity ends in `tapToCopy`.
    static var debugForceTapToCopy: Bool {
        get { AppGroup.defaults.bool(forKey: Key.debugForceTapToCopy) }
        set { AppGroup.defaults.set(newValue, forKey: Key.debugForceTapToCopy) }
    }
}
