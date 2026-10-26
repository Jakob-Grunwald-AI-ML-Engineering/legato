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
        guard !text.allSatisfy(\.isWhitespace) else { return text }
        var current = text
        for stage in stages {
            current = await run(stage, current, locale: locale)
        }
        return current
    }

    /// Runs one stage against the deadline. The stage and the timer race as unstructured tasks; the first
    /// result resumes the caller. A stage that outlives the deadline is cancelled and left to wind down in
    /// the background, so a stage that never checks for cancellation (a cold model load) cannot hold the
    /// pipeline past the timeout.
    private func run(_ stage: any TranscriptPostProcessor, _ text: String, locale: Locale) async -> String {
        let timeout = timeout
        let sleeper = sleeper
        let race = StageRace()
        let result: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                race.begin(continuation)
                let work = Task { race.finish(try? await stage.process(text, locale: locale)) }
                // The timer fires only when the sleeper returns; a cancelled sleeper throws.
                let timer = Task { if (try? await sleeper(timeout)) != nil { race.finish(nil) } }
                race.attach([work, timer])
            }
        } onCancel: {
            race.finish(nil)
        }
        guard let result, !result.allSatisfy(\.isWhitespace) else { return text }
        return result
    }
}

/// Decides a stage's run exactly once: the stage's text, or `nil` for a timeout, a failure or a cancelled
/// caller. Whoever decides cancels both tasks and resumes the caller.
private final class StageRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String?, Never>?
        var decided = false
        var outcome: String?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<String?, Never>) {
        let early: String?? = state.withLock { state in
            if state.decided { return .some(state.outcome) }
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

    func finish(_ outcome: String?) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<String?, Never>?, [Task<Void, Never>]) in
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
