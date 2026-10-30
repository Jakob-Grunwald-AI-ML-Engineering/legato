import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAppServices

private final class Base: TranscriptPostProcessor, @unchecked Sendable {
    let id = "base"
    let starts = Mutex(0)
    func process(_ text: String, locale: Locale) async throws -> String { "stateless: " + text }
    func runStarts() async throws { starts.withLock { $0 += 1 } }
}

@Suite struct AgentGatedPostProcessorTests {
    /// Without the agent on the run (no field to edit), the session's one cleanup at stop is the rolling session's
    /// rewrite, never the base processor's stateless pass; the base keeps the run's resources.
    @Test func withoutTheAgentTheStopRewritesOnTheRollingSession() async throws {
        let base = Base()
        let gate = AgentGatedPostProcessor(base, rewrite: { text, _ in text.uppercased() })
        #expect(try await gate.process("a", locale: Locale(identifier: "en")) == "A")
        try await gate.runStarts()
        #expect(base.starts.withLock { $0 } == 1)
    }

    @Test func aRewriteThatGivesNothingKeepsTheText() async throws {
        let gate = AgentGatedPostProcessor(Base(), rewrite: { _, _ in nil })
        #expect(try await gate.process("a", locale: Locale(identifier: "en")) == "a")
    }

    @Test func whileTheAgentRunsTheSessionCleansNothing() async throws {
        let gate = AgentGatedPostProcessor(Base(), rewrite: { text, _ in text.uppercased() })
        gate.agentRuns = true
        #expect(try await gate.process("a", locale: Locale(identifier: "en")) == "a")
    }
}
