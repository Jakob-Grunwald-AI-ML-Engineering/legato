import Foundation
import LegatoCore
import Synchronization

/// The dictation session's post-processor with an off switch for the run's own cleanup: while ``agentRuns`` is
/// set (the cleanup agent works on the run through the field edit queue) the session runs no rolling passes and
/// no final pass, so the agent is the only one that cleans (either live or final replace, never both). Cleared,
/// it is `base` exactly. The run's resources (`runStarts`/`runEnds`) are always `base`'s.
///
/// The switch is read when a run starts (`cleansSegmentsLive`) and at its stop (`process`): set it before the run
/// starts, clear it when the run is over.
public final class AgentGatedPostProcessor: TranscriptPostProcessor {
    private let base: any TranscriptPostProcessor
    private let gate = Mutex(false)

    public init(_ base: any TranscriptPostProcessor) { self.base = base }

    /// Whether the agent cleans the current run (the session's own cleanup stays out of it).
    public var agentRuns: Bool {
        get { gate.withLock { $0 } }
        set { gate.withLock { $0 = newValue } }
    }

    public var id: String { base.id }

    public func process(_ text: String, locale: Locale) async throws -> String {
        guard !agentRuns else {
            CleanupCallTrace.emit("cleanup.skip", ["kind": "session", "reason": "agent"])
            return text
        }
        return try await CleanupCallTrace.$kind.withValue("session") { try await base.process(text, locale: locale) }
    }

    public func runStarts() async throws { try await base.runStarts() }
    public func runEnds() async { await base.runEnds() }
    public var cleansSegmentsLive: Bool { agentRuns ? false : base.cleansSegmentsLive }

    public func cleanLivePass(_ text: String, context: String, locale: Locale, atStop: Bool) async throws -> LivePassResult {
        try await CleanupCallTrace.$kind.withValue("sessionLive") {
            try await base.cleanLivePass(text, context: context, locale: locale, atStop: atStop)
        }
    }

    public var liveStopTimeLimit: Duration? { base.liveStopTimeLimit }
    public func liveRunStarts() { base.liveRunStarts() }
}
