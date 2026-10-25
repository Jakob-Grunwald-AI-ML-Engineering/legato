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
        static let keepAliveSeconds = "keepAliveSeconds"
        static let keepSessionActiveBetweenRuns = "keepSessionActiveBetweenRuns"
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

    /// Policies the picker offers: the package's list, plus the experimental ones while the debug toggle is on.
    static var offeredPolicies: [AudioPolicy] {
        debugShowPauseOthers ? AudioPolicy.offeredPolicies + AudioPolicy.experimentalPolicies : AudioPolicy.offeredPolicies
    }

    /// How long the microphone stays ready after a keyboard dictation, so later taps skip the hop to the
    /// app. Off by default. Applies to dictation into the Legato keyboard only; the Action Button
    /// without the keyboard always releases the microphone at once.
    static var keepAlive: KeepAlive {
        get { KeepAlive(rawValue: keepAliveSeconds) ?? .off }
        set { keepAliveSeconds = newValue.rawValue }
    }

    /// The stored keep-alive in seconds. Any value works (the e2e run sets short ones); the picker
    /// offers `KeepAlive`'s cases.
    static var keepAliveSeconds: Int {
        get { max(AppGroup.defaults.integer(forKey: Key.keepAliveSeconds), 0) }
        set { AppGroup.defaults.set(max(newValue, 0), forKey: Key.keepAliveSeconds) }
    }

    static var keepAliveDuration: Duration { .seconds(keepAliveSeconds) }

    /// A light tap on every key of the Legato keyboard (needs Full Access). Default on. The keyboard reads
    /// the same keys (`KeyboardPreferences`).
    static var keyboardHaptics: Bool {
        get { AppGroup.defaults.object(forKey: KeyboardPreferences.hapticsKey) as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: KeyboardPreferences.hapticsKey) }
    }

    /// The keyboard click on every key (needs Full Access; the system's Keyboard Clicks switch also applies). Default on.
    static var keyboardClicks: Bool {
        get { AppGroup.defaults.object(forKey: KeyboardPreferences.clicksKey) as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: KeyboardPreferences.clicksKey) }
    }

    /// Debug experiment (background second-start failure): a normal stop leaves the audio session active
    /// instead of deactivating it, so the next run does not have to activate it from the background.
    /// Interruptions, media resets and lost inputs still deactivate. Default off.
    ///
    /// While the session is held, other apps' audio stays ducked (or paused, or mixed) as the policy
    /// of the last run left it: music does not recover its volume between dictations. Absent from App
    /// Store builds (`LEGATO_INTERNAL` only), where it always reads false.
    static var keepSessionActiveBetweenRuns: Bool {
        get {
            #if LEGATO_INTERNAL
            AppGroup.defaults.bool(forKey: Key.keepSessionActiveBetweenRuns)
            #else
            false
            #endif
        }
        set {
            #if LEGATO_INTERNAL
            AppGroup.defaults.set(newValue, forKey: Key.keepSessionActiveBetweenRuns)
            #endif
        }
    }

    /// Debug: offer the experimental policies (`.pauseOthers`, `.duckMusicPauseSpoken`) in the audio picker (the #6 device test).
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

/// The keep-alive choices, by seconds.
enum KeepAlive: Int, CaseIterable, Identifiable {
    case off = 0
    case seconds30 = 30
    case minute1 = 60
    case minutes2 = 120
    case minutes5 = 300
    case minutes10 = 600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .seconds30: "30 seconds"
        case .minute1: "1 minute"
        case .minutes2: "2 minutes"
        case .minutes5: "5 minutes"
        case .minutes10: "10 minutes"
        }
    }
}
