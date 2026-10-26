import Foundation
import LegatoCore
import LegatoMLX
import LegatoPostProcessing
import Observation

/// What a cleanup run did, for Settings ("what am I testing?").
public struct CleanupRunReport: Sendable, Equatable {
    public var backend: String
    public var skipped: [String]
    public var style: CleanupStyle
    public var changed: Bool
    public var milliseconds: Int
    public var refine: Bool
    /// "GPU" or "CPU" for an MLX model; nil for any other backend.
    public var device: String?

    public init(
        backend: String, skipped: [String], style: CleanupStyle, changed: Bool, milliseconds: Int, refine: Bool,
        device: String? = nil
    ) {
        self.backend = backend
        self.skipped = skipped
        self.style = style
        self.changed = changed
        self.milliseconds = milliseconds
        self.refine = refine
        self.device = device
    }
}

/// The last cleanup run's report, for Settings.
@MainActor @Observable
public final class CleanupReports {
    public private(set) var last: CleanupRunReport?
    public init() {}
    public func record(_ report: CleanupRunReport) { last = report }
}

/// The session's post-processor: resolves the cleanup pipeline per run (so GPU access and the settings
/// are read when the run ends) and reports what ran. With cleanup off it returns the text unchanged, so a
/// session kept between runs follows the switch without being rebuilt.
public struct CleanupProcessor: TranscriptPostProcessor {
    public let id = "cleanup"
    let registry: CleanupRegistry
    let settings: CleanupSettingsStore
    /// The one language the user dictates in, when the engine settings name exactly one: the prompt then
    /// writes in it (a run itself starts without a locale).
    let preferredLocale: @Sendable () -> Locale?
    /// Called when a run's cleanup begins (cleanup on), before any stage: the UI shows "Cleaning up…".
    let willRun: @Sendable () async -> Void
    let report: @Sendable (CleanupRunReport) async -> Void

    public init(
        registry: CleanupRegistry,
        settings: CleanupSettingsStore,
        preferredLocale: @escaping @Sendable () -> Locale? = { nil },
        willRun: @escaping @Sendable () async -> Void = {},
        report: @escaping @Sendable (CleanupRunReport) async -> Void
    ) {
        self.registry = registry
        self.settings = settings
        self.preferredLocale = preferredLocale
        self.willRun = willRun
        self.report = report
    }

    public func process(_ text: String, locale: Locale) async throws -> String {
        let options = settings.options
        guard options.enabled else { return text }
        await willRun()
        return await Self.run(
            text, locale: preferredLocale() ?? locale, style: options.style, refine: false,
            timeout: .seconds(options.timeoutSeconds), settings: settings, registry: registry, report: report)
    }

    /// One cleanup in `style`, whatever the on/off switch says (refine uses it directly). ITN and the backend
    /// come from `settings`.
    public static func run(
        _ text: String, locale: Locale, style: CleanupStyle, refine: Bool, timeout: Duration,
        settings: CleanupSettingsStore, registry: CleanupRegistry, report: @Sendable (CleanupRunReport) async -> Void
    ) async -> String {
        let clock = ContinuousClock()
        let start = clock.now
        let itn = settings.itn
        let (pipeline, resolution) = await registry.pipeline(
            style: style, itn: itn, preference: settings.backend.preference, background: settings.backgroundCleanup,
            timeout: timeout)
        let out = await pipeline.process(text, locale: locale)
        let elapsed = start.duration(to: clock.now)
        await report(CleanupRunReport(
            backend: name(resolution.choice, itn: itn), skipped: resolution.skipped.map(\.description), style: style,
            changed: out != text, milliseconds: Int(elapsed / .milliseconds(1)), refine: refine,
            device: resolution.device?.label))
        return out
    }

    public static func name(_ choice: CleanupRegistry.Choice, itn: Bool) -> String {
        switch choice {
        case .mlx(let id): MLXModels.spec(id: id)?.displayName ?? id
        case .foundationModels: "Apple Foundation Models"
        case .itnOnly: itn ? "ITN only (no language model)" : "None (no language model)"
        }
    }
}
