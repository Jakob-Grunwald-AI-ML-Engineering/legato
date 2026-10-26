import Foundation
import LegatoCore
import LegatoKeyboardCore
import LegatoMLX
import LegatoPostProcessing

/// Which backend cleanup uses. Stored as its raw value.
enum CleanupBackendChoice: String, CaseIterable, Sendable {
    /// The picked MLX model in the foreground, else Apple Foundation Models.
    case auto
    /// Apple Foundation Models only.
    case foundationModels
    /// The picked MLX model (falls through to Apple Foundation Models where MLX can't run: background).
    case mlx

    var preference: CleanupRegistry.BackendPreference { self == .foundationModels ? .foundationModels : .auto }
}

/// The cleanup settings, in the App Group's `UserDefaults`. Off by default.
extension Settings {
    private enum CleanupKey {
        static let enabled = "cleanup.enabled"
        static let delivery = "cleanup.delivery"
        static let style = "cleanup.style"
        static let backend = "cleanup.backend"
        static let itn = "cleanup.itn"
        static let timeoutSeconds = "cleanup.timeoutSeconds"
    }

    static var cleanupEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: CleanupKey.enabled) }
        set { AppGroup.defaults.set(newValue, forKey: CleanupKey.enabled) }
    }

    /// How a cleaned text reaches a field the raw text streamed into. Default `.replace`.
    static var cleanupDelivery: CleanupDelivery {
        get { AppGroup.defaults.string(forKey: CleanupKey.delivery).flatMap(CleanupDelivery.init(rawValue:)) ?? .replace }
        set { AppGroup.defaults.set(newValue.rawValue, forKey: CleanupKey.delivery) }
    }

    static var cleanupStyle: CleanupStyle {
        get { AppGroup.defaults.string(forKey: CleanupKey.style).flatMap(CleanupStyle.init(rawValue:)) ?? .verbatim }
        set { AppGroup.defaults.set(newValue.rawValue, forKey: CleanupKey.style) }
    }

    static var cleanupBackend: CleanupBackendChoice {
        get { AppGroup.defaults.string(forKey: CleanupKey.backend).flatMap(CleanupBackendChoice.init(rawValue:)) ?? .auto }
        set { AppGroup.defaults.set(newValue.rawValue, forKey: CleanupKey.backend) }
    }

    /// Inverse text normalization before the LLM. Default off: FluidAudio's English ITN merges "ten thirty"
    /// into "40" (#22).
    static var cleanupITN: Bool {
        get { AppGroup.defaults.bool(forKey: CleanupKey.itn) }
        set { AppGroup.defaults.set(newValue, forKey: CleanupKey.itn) }
    }

    /// Per-stage limit, 1 to 10 seconds. Default 4.
    static var cleanupTimeoutSeconds: Int {
        get {
            let stored = AppGroup.defaults.integer(forKey: CleanupKey.timeoutSeconds)
            return stored == 0 ? 4 : min(max(stored, 1), 10)
        }
        set { AppGroup.defaults.set(min(max(newValue, 1), 10), forKey: CleanupKey.timeoutSeconds) }
    }

    /// What the keyboard is told about a run that starts now: nil with cleanup off.
    static var hostDelivery: HostDelivery? {
        guard cleanupEnabled else { return nil }
        switch cleanupDelivery {
        case .replace: return .replace
        case .clipboard: return .clipboard
        case .hold: return .hold
        }
    }
}

/// What the last cleanup run did, for Settings ("what am I testing?").
struct CleanupRunReport: Sendable, Equatable {
    var backend: String
    var skipped: [String]
    var style: CleanupStyle
    var changed: Bool
    var milliseconds: Int
    var refine: Bool
}

/// The session's post-processor: resolves the cleanup pipeline per run (so GPU access and the settings
/// are read when the run ends) and reports what ran. With cleanup off it returns the text unchanged, so a
/// session kept between runs (keep-ready) follows the switch without re-arming the microphone.
struct CleanupProcessor: TranscriptPostProcessor {
    let id = "cleanup"
    let registry: CleanupRegistry
    /// The one language the user dictates in, when the engine settings name exactly one: the prompt then
    /// writes in it (a run itself starts without a locale).
    let preferredLocale: @Sendable () -> Locale?
    let report: @Sendable (CleanupRunReport) async -> Void

    func process(_ text: String, locale: Locale) async throws -> String {
        guard Settings.cleanupEnabled else { return text }
        return await Self.run(
            text, locale: preferredLocale() ?? locale, style: Settings.cleanupStyle, refine: false,
            timeout: .seconds(Settings.cleanupTimeoutSeconds), registry: registry, report: report)
    }

    /// One cleanup in `style`, whatever the on/off switch says (refine uses it directly).
    static func run(
        _ text: String, locale: Locale, style: CleanupStyle, refine: Bool, timeout: Duration,
        registry: CleanupRegistry, report: @Sendable (CleanupRunReport) async -> Void
    ) async -> String {
        let clock = ContinuousClock()
        let start = clock.now
        let (pipeline, resolution) = await registry.pipeline(
            style: style, itn: Settings.cleanupITN, preference: Settings.cleanupBackend.preference, timeout: timeout)
        let out = await pipeline.process(text, locale: locale)
        let elapsed = start.duration(to: clock.now)
        await report(CleanupRunReport(
            backend: Self.name(resolution.choice), skipped: resolution.skipped.map(\.description), style: style,
            changed: out != text, milliseconds: Int(elapsed / .milliseconds(1)),
            refine: refine))
        return out
    }

    static func name(_ choice: CleanupRegistry.Choice) -> String {
        switch choice {
        case .mlx(let id): MLXModels.spec(id: id)?.displayName ?? id
        case .foundationModels: "Apple Foundation Models"
        case .itnOnly: Settings.cleanupITN ? "ITN only (no language model)" : "None (no language model)"
        }
    }
}
