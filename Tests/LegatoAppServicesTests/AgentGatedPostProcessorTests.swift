import Foundation
import LegatoCore
import Testing
@testable import LegatoAppServices

private struct LiveProcessor: TranscriptPostProcessor {
    let id = "live"
    var cleansSegmentsLive: Bool { true }
    func process(_ text: String, locale: Locale) async throws -> String { text.uppercased() }
}

@Suite struct AgentGatedPostProcessorTests {
    @Test func offIsTheBaseProcessor() async throws {
        let gate = AgentGatedPostProcessor(LiveProcessor())
        #expect(gate.cleansSegmentsLive)
        #expect(try await gate.process("a", locale: Locale(identifier: "en")) == "A")
    }

    @Test func whileTheAgentRunsTheSessionCleansNothing() async throws {
        let gate = AgentGatedPostProcessor(LiveProcessor())
        gate.agentRuns = true
        #expect(!gate.cleansSegmentsLive)
        #expect(try await gate.process("a", locale: Locale(identifier: "en")) == "a")
        gate.agentRuns = false
        #expect(gate.cleansSegmentsLive)
    }
}
