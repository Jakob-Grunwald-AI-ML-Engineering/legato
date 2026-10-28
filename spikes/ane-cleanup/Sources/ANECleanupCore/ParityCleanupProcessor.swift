import Foundation
import Synchronization
import LegatoCore
import LegatoAppServices
import LegatoPostProcessing
import LegatoVocabulary

/// Operational evidence contains no transcript, prompt, or generated candidate.
public struct ParityCleanupEvent: Sendable {
    public var status: String
    public var invocations: Int
    public var failedInvocations: Int
    public var refine: Bool
}

/// Spike-only backend composition. Settings, prompt, guard, timeout and delivery use production contracts.
public final class ParityCleanupProcessor: TranscriptPostProcessor {
    public let id = "ane-parity-cleanup"
    public static let backendName = "ANEMLL Qwen3-1.7B"
    public static let deviceLabel = "CPU + Neural Engine requested; placement unverified"
    private let owner: ParityModelOwner
    private let settings: CleanupSettingsStore
    private let preferredLocale: @Sendable () -> Locale?
    private let vocabulary: VocabularyService?
    private let event: @Sendable (ParityCleanupEvent) -> Void
    private let report: @Sendable (CleanupRunReport) async -> Void
    private let live = Mutex((runID: UUID(), report: Optional<CleanupRunReport>.none))

    public init(
        owner: ParityModelOwner, settings: CleanupSettingsStore,
        preferredLocale: @escaping @Sendable () -> Locale? = { nil }, vocabulary: VocabularyService? = nil,
        event: @escaping @Sendable (ParityCleanupEvent) -> Void = { _ in },
        report: @escaping @Sendable (CleanupRunReport) async -> Void = { _ in }
    ) {
        self.owner = owner; self.settings = settings; self.preferredLocale = preferredLocale
        self.vocabulary = vocabulary; self.event = event; self.report = report
    }
    public var cleansSegmentsLive: Bool { settings.enabled && settings.delivery == .live }
    public var liveStopTimeLimit: Duration? { settings.enabled ? .seconds(settings.timeoutSeconds) : nil }
    public func liveRunStarts() { live.withLock { $0 = (UUID(), nil) } }
    public func process(_ text: String, locale: Locale) async throws -> String {
        let options = settings.options
        guard options.enabled else { return text }
        return await run(text, locale: preferredLocale() ?? locale, style: options.style,
                         timeout: .seconds(options.timeoutSeconds)).text
    }
    public func cleanLivePass(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> LivePassResult {
        let options = settings.options
        guard options.enabled else { return LivePassResult(text: text) }
        return await run(text, locale: preferredLocale() ?? locale, style: options.style,
                         timeout: .seconds(options.timeoutSeconds), context: context, livePass: true)
    }
    /// Refine calls this with Message style and the production doubled/minimum-eight-second limit.
    public func run(
        _ text: String, locale: Locale, style: CleanupStyle, timeout: Duration,
        context: String = "", refine: Bool = false, livePass: Bool = false
    ) async -> LivePassResult {
        let started = ContinuousClock.now
        let id = UUID().uuidString
        let ledger = BackendInvocationLedger()
        let backend = LedgerBackend(owner: owner, ledger: ledger, runID: id)
        let terms = await vocabulary?.cleanupTerms(for: text) ?? []
        var stages: [any TranscriptPostProcessor] = settings.itn ? [ITNStage()] : []
        stages.append(LLMCleanupStage(backend: backend, cleanupGuard: style.cleanupGuard,
                                     vocabulary: terms, prompt: style.prompt, context: context))
        let output = await PostProcessingPipeline(stages: stages, timeout: timeout).processReporting(text, locale: locale)
        let summary = ledger.summary(for: id)
        let status = summary.voiceStatus(cancelled: Task.isCancelled, timedOut: output.timedOut,
                                         guardRejected: output.guardRejected && summary.allSucceeded, capped: false)
        event(ParityCleanupEvent(status: status, invocations: summary.invocationCount,
                                 failedInvocations: summary.failedInvocationCount, refine: refine))
        let learningID = livePass ? live.withLock { $0.runID } : UUID()
        if output.text != text {
            vocabulary?.learnFromCleanup(raw: text, cleaned: output.text, style: style, runID: learningID,
                                         locale: locale, suggested: terms)
        }
        var runReport = CleanupRunReport(
            backend: Self.backendName, skipped: status == "completed" ? [] : [status], style: style,
            changed: output.text != text, milliseconds: Int(started.duration(to: .now) / .milliseconds(1)),
            refine: refine, device: Self.deviceLabel)
        if livePass {
            runReport = live.withLock { value in
                if let previous = value.report {
                    runReport.milliseconds += previous.milliseconds
                    runReport.changed = runReport.changed || previous.changed
                    for reason in previous.skipped where !runReport.skipped.contains(reason) { runReport.skipped.append(reason) }
                }
                value.report = runReport
                return runReport
            }
        }
        await report(runReport)
        return LivePassResult(text: output.text, guardRejected: output.guardRejected, timedOut: output.timedOut,
                              backend: Self.backendName, device: Self.deviceLabel)
    }
}
private struct LedgerBackend: LLMBackend {
    let owner: ParityModelOwner
    let ledger: BackendInvocationLedger
    let runID: String
    var id: String { owner.id }
    var maxPromptCharacters: Int? { owner.maxPromptCharacters }
    var availability: LLMAvailability { get async { await owner.availability } }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        try await ledger.respond(runID: runID) {
            try await owner.respond(instructions: instructions, examples: examples, prompt: prompt)
        }
    }
}
