import Foundation
import LegatoCore

/// Runs ``TranscriptPostProcessor`` stages in order over a transcript.
///
/// The pipeline never fails and never loses text: a stage that throws (a guardrail refusal included),
/// that runs past the timeout, or that returns nothing leaves its input unchanged for the next stage.
/// Blank input short-circuits without calling any stage.
///
/// A stage must honor task cancellation for the timeout to return promptly; the pipeline cancels it
/// and waits for it to finish.
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

    private func run(_ stage: any TranscriptPostProcessor, _ text: String, locale: Locale) async -> String {
        let timeout = timeout
        let sleeper = sleeper
        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await stage.process(text, locale: locale) }
            group.addTask {
                // Finishing first (or being cancelled) with nothing means "timed out".
                try? await sleeper(timeout)
                return nil
            }
            // Whichever child finishes first decides; the stage's result is non-nil only on success.
            var outcome: String?
            for await value in group {
                if let value { outcome = value }
                group.cancelAll()
                break
            }
            return outcome
        }
        guard let result, !result.allSatisfy(\.isWhitespace) else { return text }
        return result
    }
}
