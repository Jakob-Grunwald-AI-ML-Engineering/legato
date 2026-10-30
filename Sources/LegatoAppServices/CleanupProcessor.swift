import Foundation
import LegatoCore
import LegatoCoreML
import LegatoPostProcessing
import Observation
import Synchronization

/// The exact backend admitted for one run, retained independently of later selections/readiness.
public struct CleanupRunLease: Sendable {
    public let resolution: CleanupRegistry.Resolution
    let release: @Sendable () async -> Void
    public init(resolution: CleanupRegistry.Resolution, release: @escaping @Sendable () async -> Void) {
        self.resolution = resolution; self.release = release
    }
}

private final class FrozenCleanupOptions: Sendable {
    let value = Mutex<CleanupOptions?>(nil)
}

private actor RunCleanup {
    var lease: CleanupRunLease?
    var resolution: CleanupRegistry.Resolution? { lease?.resolution }
    func begin(_ lease: CleanupRunLease?) { self.lease = lease }
    func end() async {
        let old = lease; lease = nil
        await old?.release()
    }
}

/// What a cleanup run did, for Settings ("what am I testing?").
public struct CleanupRunReport: Sendable, Equatable {
    public var backend: String
    public var skipped: [String]
    public var style: CleanupStyle
    public var changed: Bool
    public var milliseconds: Int
    public var refine: Bool
    /// Configured execution policy when supplied by the backend; physical placement remains unverified.
    public var device: String?
    public var outcome: String = "completed"

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

/// The session's post-processor: captures options and the backend lease at run admission, then reports
/// what ran. Settings changes apply to the next run. Cleanup off retains the source text.
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
    /// Supplies the `<terms>` for the model and learns from what a run changed; nil: neither.
    private let vocabulary: VocabularyService?
    private let acquireRun: (@Sendable () async throws -> CleanupRunLease?)?
    private let runCleanup = RunCleanup()
    private let frozenOptions = FrozenCleanupOptions()
    private let acquireRunWithOptions: (@Sendable (CleanupOptions) async throws -> CleanupRunLease?)?

    private var options: CleanupOptions { frozenOptions.value.withLock { $0 } ?? settings.options }

    public init(
        registry: CleanupRegistry,
        settings: CleanupSettingsStore,
        preferredLocale: @escaping @Sendable () -> Locale? = { nil },
        willRun: @escaping @Sendable () async -> Void = {},
        vocabulary: VocabularyService? = nil,
        acquireRun: (@Sendable () async throws -> CleanupRunLease?)? = nil,
        acquireRunWithOptions: (@Sendable (CleanupOptions) async throws -> CleanupRunLease?)? = nil,
        report: @escaping @Sendable (CleanupRunReport) async -> Void
    ) {
        self.acquireRun = acquireRun
        self.acquireRunWithOptions = acquireRunWithOptions
        self.vocabulary = vocabulary
        self.registry = registry
        self.settings = settings
        self.preferredLocale = preferredLocale
        self.willRun = willRun
        self.report = report
    }

    public func runStarts() async throws {
        await runCleanup.end()
        let captured = settings.options
        frozenOptions.value.withLock { $0 = captured }
        do {
            if let acquireRunWithOptions {
                await runCleanup.begin(try await acquireRunWithOptions(captured))
            } else if let acquireRun {
                await runCleanup.begin(try await acquireRun())
            } else if captured.enabled {
                let resolution = await registry.resolve(preference: captured.backend.preference)
                await runCleanup.begin(CleanupRunLease(resolution: resolution, release: {}))
            }
            try Task.checkCancellation()
        } catch {
            await runCleanup.end()
            frozenOptions.value.withLock { $0 = nil }
            throw error
        }
    }
    public func runEnds() async {
        await runCleanup.end()
        frozenOptions.value.withLock { $0 = nil }
    }

    public func process(_ text: String, locale: Locale) async throws -> String {
        let options = self.options
        guard options.enabled else { return text }
        await willRun()
        let resolution = await runCleanup.resolution
        return await CleanupCallTrace.$kind.withValue("session") {
            await Self.run(
                text, locale: preferredLocale() ?? locale, style: options.style, refine: false,
                timeout: .seconds(options.timeoutSeconds), settings: settings, registry: registry, report: report,
                vocabulary: vocabulary, runID: UUID(), resolution: resolution, options: options)
        }
    }

    /// One cleanup in `style`, whatever the on/off switch says (refine uses it directly). ITN and the backend
    /// come from `settings`. `context`: the frozen cleaned text before `text` (a live pass past the length cap).
    /// `vocabulary`: its terms go to the model, and what the run changed teaches it (as run `runID`), in the
    /// background, except a swap to one of the terms the model was given (not independent evidence). A run has
    /// no dictation id, so deleting a dictation does not unlearn its run's pending fixes (see
    /// ``VocabularyService/learnFromCleanup``).
    public static func run(
        _ text: String, locale: Locale, style: CleanupStyle, refine: Bool, timeout: Duration,
        settings: CleanupSettingsStore, registry: CleanupRegistry, report: @Sendable (CleanupRunReport) async -> Void,
        context: String = "", vocabulary: VocabularyService? = nil, runID: UUID = UUID(),
        resolution: CleanupRegistry.Resolution? = nil, options: CleanupOptions? = nil
    ) async -> String {
        await runReporting(
            text, locale: locale, style: style, refine: refine, timeout: timeout, settings: settings, registry: registry,
            report: report, context: context, vocabulary: vocabulary, runID: runID, resolution: resolution, options: options).pipeline.text
    }

    /// ``run(_:locale:style:refine:timeout:settings:registry:report:context:)`` with the pipeline's report and
    /// the run's.
    static func runReporting(
        _ text: String, locale: Locale, style: CleanupStyle, refine: Bool, timeout: Duration,
        settings: CleanupSettingsStore, registry: CleanupRegistry, report: @Sendable (CleanupRunReport) async -> Void,
        context: String = "", vocabulary: VocabularyService? = nil, runID: UUID = UUID(),
        resolution: CleanupRegistry.Resolution? = nil, options: CleanupOptions? = nil
    ) async -> (pipeline: PostProcessingPipeline.Report, report: CleanupRunReport) {
        let clock = ContinuousClock()
        let start = clock.now
        let options = options ?? settings.options
        let itn = options.itn && style == .verbatim
        let terms = await vocabulary?.cleanupTerms(for: text) ?? []
        let (pipeline, resolution) = await registry.pipeline(
            style: style, itn: itn, preference: options.backend.preference,
            timeout: timeout, context: context, vocabulary: terms, resolution: resolution, emoji: options.emoji)
        let out = await pipeline.processReporting(text, locale: locale)
        if out.text != text {
            vocabulary?.learnFromCleanup(
                raw: text, cleaned: out.text, style: style, runID: runID, locale: locale, suggested: terms)
        }
        let elapsed = start.duration(to: clock.now)
        var run = CleanupRunReport(
            backend: name(resolution.choice, itn: itn), skipped: resolution.skipped.map(\.description), style: style,
            changed: out.text != text, milliseconds: Int(elapsed / .milliseconds(1)), refine: refine,
            device: resolution.execution)
        run.outcome = Task.isCancelled ? "cancelled"
            : out.timedOut ? "timedOut"
            : out.guardRejected ? "guardRejected"
            : out.failed || resolution.backend == nil ? "rawOrUnavailable" : "completed"
        CleanupCallTrace.emit("cleanup.call", [
            "kind": CleanupCallTrace.kind, "backend": run.backend, "ms": String(run.milliseconds),
            "outcome": run.outcome, "changed": run.changed ? "1" : "0", "inChars": String(text.count),
        ])
        await report(run)
        return (out, run)
    }

    public static func name(_ choice: CleanupRegistry.Choice, itn: Bool) -> String {
        switch choice {
        case .coreML(let id): CoreMLModels.spec(id: id)?.displayName ?? id
        case .foundationModels: "Apple Foundation Models"
        case .itnOnly: itn ? "ITN only (no language model)" : "None (no language model)"
        }
    }
}

extension CleanupRunLease {
    /// Gives the admitted backend back.
    public func end() async { await release() }
}

/// One cleanup pass outside a session's run (the final pass of a run whose cleanup agent was absent): it
/// takes the same lease a run takes at its start, so the pass runs on the admitted backend (the Foundation Models
/// bridge while a Core ML load is still warming) and neither contends with that load nor has it retired mid-pass.
public enum LeasedCleanup {
    /// Runs `pass` with the resolution of a lease acquired by `acquire`, then releases the lease. Nil when no lease
    /// came within `limit` (a late one is released as soon as it arrives) or `acquire` failed: the caller keeps its
    /// text. Only the acquisition is bounded; the pass has its own time limit.
    public static func run(
        acquire: @escaping @Sendable () async throws -> CleanupRunLease?, within limit: Duration,
        pass: @Sendable (CleanupRegistry.Resolution?) async -> String?
    ) async -> String? {
        let race = LeaseRace()
        let acquired: Acquired = await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task {
                do {
                    let lease = try await acquire()
                    if !race.settle(.lease(lease)) { await lease?.end() }
                } catch {
                    _ = race.settle(.unavailable)
                }
            }
            Task {
                try? await Task.sleep(for: limit)
                _ = race.settle(.unavailable)
            }
        }
        guard case .lease(let lease) = acquired else { return nil }
        let out = await pass(lease?.resolution)
        await lease?.end()
        return out
    }

    private enum Acquired: Sendable {
        case lease(CleanupRunLease?)
        case unavailable
    }

    /// Settles once, from whichever side answers first.
    private final class LeaseRace: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var continuation: CheckedContinuation<Acquired, Never>?

        /// Whether this answer was the first.
        func settle(_ value: Acquired) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            continuation?.resume(returning: value)
            return true
        }
    }
}
