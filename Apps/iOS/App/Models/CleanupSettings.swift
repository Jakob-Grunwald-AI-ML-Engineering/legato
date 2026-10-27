import Foundation
import LegatoAppServices
import LegatoCore
import LegatoKeyboardCore
import LegatoMLX
import LegatoPostProcessing

/// The cleanup settings, in the App Group's `UserDefaults` (`CleanupSettingsStore`). Off by default.
extension Settings {
    static var cleanupStore: CleanupSettingsStore { CleanupSettingsStore(defaults: AppGroup.defaults) }

    static var cleanupEnabled: Bool {
        get { cleanupStore.enabled }
        set { cleanupStore.enabled = newValue }
    }

    /// How a cleaned text reaches a field the raw text streamed into. Default `.replace`.
    static var cleanupDelivery: CleanupDelivery {
        get { cleanupStore.delivery }
        set { cleanupStore.delivery = newValue }
    }

    static var cleanupStyle: CleanupStyle {
        get { cleanupStore.style }
        set { cleanupStore.style = newValue }
    }

    static var cleanupBackend: CleanupBackendChoice {
        get { cleanupStore.backend }
        set { cleanupStore.backend = newValue }
    }

    /// Inverse text normalization before the LLM. Default off (#22).
    static var cleanupITN: Bool {
        get { cleanupStore.itn }
        set { cleanupStore.itn = newValue }
    }

    /// Per-stage limit, 1 to 10 seconds. Default 4.
    static var cleanupTimeoutSeconds: Int {
        get { cleanupStore.timeoutSeconds }
        set { cleanupStore.timeoutSeconds = newValue }
    }

    /// What cleanup runs while the app is in the background (no GPU there). Default the CPU.
    static var cleanupBackground: CleanupRegistry.BackgroundCleanup {
        get { cleanupStore.backgroundCleanup }
        set { cleanupStore.backgroundCleanup = newValue }
    }

    /// What the keyboard is told about a run that starts now: nil with cleanup off.
    static var hostDelivery: HostDelivery? {
        guard cleanupEnabled else { return nil }
        switch cleanupDelivery {
        case .replace: return .replace
        case .clipboard: return .clipboard
        case .hold: return .hold
        case .live: return .live
        }
    }
}

extension ModelServices {
    /// `<App Group container>/Models`, or the app's own Application Support when the App Group is
    /// unavailable (like the history file).
    static var phoneModelsRoot: URL {
        let base = AppGroup.containerURL
            ?? URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        return base.appending(path: "Models", directoryHint: .isDirectory)
    }
}
