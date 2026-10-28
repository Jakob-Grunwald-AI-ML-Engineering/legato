import Foundation
import LegatoCore
import Synchronization

/// Runs ``TranscriptPostProcessor`` stages in order over a transcript.
///
/// The pipeline never fails and never loses text: a stage that throws (a guardrail refusal included),
/// that runs past the timeout, or that returns nothing leaves its input unchanged for the next stage.
/// Blank input short-circuits without calling any stage.
///
/// The timeout bounds the pipeline's latency whatever the stage does: at the deadline the stage is
/// cancelled and the pipeline moves on without waiting for it, so a stage that never checks for
/// cancellation keeps running in the background until it ends on its own.
public struct PostProcessingPipeline: Sendable {
    public let stages: [any TranscriptPostProcessor]
    /// How long one stage may run.
    public let timeout: Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - stages: run in this order.
    ///   - timeout: per-stage limit; 4 s by default.
    ///   - sleeper: waits for the timeout. Injected so tests run fast; throws when cancelled.
    public init(
        stages: [any TranscriptPostProcessor],
        timeout: Duration = .seconds(4),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.stages = stages
        self.timeout = timeout
        self.sleeper = sleeper
    }

    public func process(_ text: String, locale: Locale) async -> String {
        await processReporting(text, locale: locale).text
    }

    /// What a run did beyond its text, for live cleanup's trace.
    public struct Report: Sendable, Equatable {
        public var text: String
        /// A stage ran past the timeout (its input was kept).
        public var timedOut: Bool
        /// A language model's reply was rejected by the cleanup guard (its input was kept, all or in part).
        public var guardRejected: Bool
        /// A stage failed or was canceled and its input was kept.
        public var failed: Bool = false
    }

    /// ``process(_:locale:)`` with what happened on the way.
    public func processReporting(_ text: String, locale: Locale) async -> Report {
        var report = Report(text: text, timedOut: false, guardRejected: false)
        guard !text.allSatisfy(\.isWhitespace) else { return report }
        for stage in stages {
            switch await run(stage, report.text, locale: locale) {
            case .text(let out, let rejected):
                if !out.allSatisfy(\.isWhitespace) { report.text = out }
                report.guardRejected = report.guardRejected || rejected
            case .timedOut:
                report.timedOut = true
            case .failed:
                report.failed = true
            }
        }
        return report
    }

    /// Runs one stage against the deadline. The stage and the timer race as unstructured tasks; the first
    /// result resumes the caller. A stage that outlives the deadline is cancelled and left to wind down in
    /// the background, so a stage that never checks for cancellation (a cold model load) cannot hold the
    /// pipeline past the timeout.
    private func run(_ stage: any TranscriptPostProcessor, _ text: String, locale: Locale) async -> StageOutcome {
        let timeout = timeout
        let sleeper = sleeper
        let race = StageRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StageOutcome, Never>) in
                race.begin(continuation)
                let work = Task {
                    do {
                        if let guarded = stage as? any GuardedStage {
                            let out = try await guarded.processGuarded(text, locale: locale)
                            race.finish(.text(out.text, rejected: out.rejected))
                        } else {
                            race.finish(.text(try await stage.process(text, locale: locale), rejected: false))
                        }
                    } catch {
                        race.finish(.failed)
                    }
                }
                // The timer fires only when the sleeper returns; a cancelled sleeper throws.
                let timer = Task { if (try? await sleeper(timeout)) != nil { race.finish(.timedOut) } }
                race.attach([work, timer])
            }
        } onCancel: {
            race.finish(.failed)
        }
    }
}

/// How one stage's run ended.
enum StageOutcome: Sendable {
    case text(String, rejected: Bool)
    case timedOut
    /// It threw, or the caller was cancelled.
    case failed
}

/// A stage that can tell when the cleanup guard rejected a reply (and the input was kept).
protocol GuardedStage: TranscriptPostProcessor {
    func processGuarded(_ text: String, locale: Locale) async throws -> (text: String, rejected: Bool)
}

/// Decides a stage's run exactly once: its outcome, a timeout or a failure (a cancelled caller included).
/// Whoever decides cancels both tasks and resumes the caller.
private final class StageRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<StageOutcome, Never>?
        var decided = false
        var outcome: StageOutcome = .failed
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<StageOutcome, Never>) {
        let early: StageOutcome? = state.withLock { state in
            if state.decided { return state.outcome }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        let decided = state.withLock { state -> Bool in
            if !state.decided { state.tasks = tasks }
            return state.decided
        }
        if decided { tasks.forEach { $0.cancel() } }
    }

    func finish(_ outcome: StageOutcome) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<StageOutcome, Never>?, [Task<Void, Never>]) in
            guard !state.decided else { return (nil, []) }
            state.decided = true
            state.outcome = outcome
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: outcome)
    }
}
