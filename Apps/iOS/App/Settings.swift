import Foundation
import LegatoCore
import LegatoKeyboardCore

/// The App Group, shared with the widget extension and (later) the keyboard.
enum AppGroup {
    static let id = LinkChannel.appGroupID

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// User settings, in the App Group's `UserDefaults`.
enum Settings {
    private enum Key {
        static let audioPolicy = "audioPolicy"
        static let keepAliveSeconds = "keepAliveSeconds"
        static let keepAliveChoicesVersion = "keepAliveChoicesVersion"
        static let fieldEdits = "fieldEdits"
        #if LEGATO_INTERNAL
        static let keepSessionActiveBetweenRuns = "keepSessionActiveBetweenRuns"
        static let debugShowPauseOthers = "debugShowPauseOthers"
        static let debugForceTapToCopy = "debugForceTapToCopy"
        #endif
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

    /// How long the microphone stays ready after a dictation (Action Button, Control Center or the Legato
    /// keyboard), so the next start skips activating the audio session. Off by default.
    static var keepAlive: KeepAliveChoice {
        get { KeepAliveChoice(migratingStoredSeconds: keepAliveSeconds) }
        set { keepAliveSeconds = newValue.rawValue }
    }

    /// The stored keep-alive in seconds, `-1` for indefinitely. Any value works (the e2e run sets short
    /// ones); the picker offers `KeepAliveChoice`'s cases.
    static var keepAliveSeconds: Int {
        get { AppGroup.defaults.integer(forKey: Key.keepAliveSeconds) }
        set { AppGroup.defaults.set(max(newValue, -1), forKey: Key.keepAliveSeconds) }
    }

    /// What a press starts with: the stored value as it is, so a short e2e value stays short.
    static var keepAliveLinger: Linger {
        let seconds = keepAliveSeconds
        return seconds < 0 ? .indefinite : .seconds(seconds)
    }

    /// Once: moves a keep-alive stored by an earlier version (30 s and 2 min were offered) onto the
    /// current choices. Run before anything reads the setting.
    static func migrateKeepAliveChoices() {
        let defaults = AppGroup.defaults
        guard defaults.integer(forKey: Key.keepAliveChoicesVersion) < 2 else { return }
        if defaults.object(forKey: Key.keepAliveSeconds) != nil {
            keepAlive = KeepAliveChoice(migratingStoredSeconds: keepAliveSeconds)
        }
        defaults.set(2, forKey: Key.keepAliveChoicesVersion)
    }

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

    /// Hand credential fields to the next enabled keyboard once per field. Default off.
    static var keyboardAutomaticAutoFill: Bool {
        get { AppGroup.defaults.object(forKey: AutoFillHandoff.preferenceKey) as? Bool ?? AutoFillHandoff.defaultEnabled }
        set { AppGroup.defaults.set(newValue, forKey: AutoFillHandoff.preferenceKey) }
    }

    /// The compact keyboard: one row with the dictation status, the mic key and a chevron that expands to the
    /// full keyboard. The keyboard reads the same key (`KeyboardPreferences`). Default off.
    static var keyboardStrip: Bool {
        get { AppGroup.defaults.object(forKey: KeyboardPreferences.stripKey) as? Bool ?? false }
        set { AppGroup.defaults.set(newValue, forKey: KeyboardPreferences.stripKey) }
    }

    /// Debug experiment: the height (points) a strip session starts with, one of `StripHeight.candidates`.
    /// The keyboard honours it in DEBUG builds only (a long press on its status text steps through them).
    static var keyboardStripHeight: Double {
        get { StripHeight.resolve(stored: AppGroup.defaults.object(forKey: KeyboardPreferences.stripHeightKey) as? Double) }
        set { AppGroup.defaults.set(newValue, forKey: KeyboardPreferences.stripHeightKey) }
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
    /// Stored values are honoured in `LEGATO_INTERNAL` builds only; a Release build always reads false, whatever
    /// the App Group holds (it is shared with the other targets and could carry a value from an earlier build).
    static var debugShowPauseOthers: Bool {
        get {
            #if LEGATO_INTERNAL
            AppGroup.defaults.bool(forKey: Key.debugShowPauseOthers)
            #else
            false
            #endif
        }
        set {
            #if LEGATO_INTERNAL
            AppGroup.defaults.set(newValue, forKey: Key.debugShowPauseOthers)
            #endif
        }
    }

    /// "Experimental: edit queue and cleanup agent". Off by default; frozen per run (`HostState.fieldEdits`).
    /// Available in release builds.
    static var fieldEdits: Bool {
        get { AppGroup.defaults.bool(forKey: Key.fieldEdits) }
        set { AppGroup.defaults.set(newValue, forKey: Key.fieldEdits) }
    }

    /// Debug: the pasteboard client reports "didn't change", so the activity ends in `tapToCopy`. `LEGATO_INTERNAL`
    /// builds only, like `debugShowPauseOthers`.
    static var debugForceTapToCopy: Bool {
        get {
            #if LEGATO_INTERNAL
            AppGroup.defaults.bool(forKey: Key.debugForceTapToCopy)
            #else
            false
            #endif
        }
        set {
            #if LEGATO_INTERNAL
            AppGroup.defaults.set(newValue, forKey: Key.debugForceTapToCopy)
            #endif
        }
    }
}

extension KeepAliveChoice {
    var title: String {
        switch self {
        case .off: "Off"
        case .minute1: "1 minute"
        case .minutes5: "5 minutes"
        case .minutes10: "10 minutes"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        case .indefinitely: "Indefinitely"
        }
    }
}
