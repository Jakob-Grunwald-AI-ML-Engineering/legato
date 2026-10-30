import Foundation
import LegatoCore
import Synchronization

/// The dictation session's post-processor (#80): the cleanup agent is the only cleanup, so the session never cleans
/// live, and its one cleanup at stop is the rolling session's whole-text rewrite (``PassageRewriter``, through
/// `rewrite`), never a separate pass on another session. While ``agentRuns`` is set (the agent cleans the run
/// through the field edit queue) the session cleans nothing at all. The run's resources (`runStarts`/`runEnds`)
/// are always `base`'s.
///
/// The switch is read at the stop (`process`): set it before the run starts, clear it when the run is over.
public final class AgentGatedPostProcessor: TranscriptPostProcessor {
    /// Rewrites a whole text on the rolling session; nil when it changed nothing or could not run.
    public typealias Rewrite = @Sendable (_ text: String, _ locale: Locale) async -> String?

    private let base: any TranscriptPostProcessor
    private let rewrite: Rewrite
    private let gate = Mutex(false)

    public init(_ base: any TranscriptPostProcessor, rewrite: @escaping Rewrite) {
        self.base = base
        self.rewrite = rewrite
    }

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
        let rewrite = rewrite
        return await CleanupCallTrace.$kind.withValue("session") { await rewrite(text, locale) } ?? text
    }

    public func runStarts() async throws { try await base.runStarts() }
    public func runEnds() async { await base.runEnds() }
}
