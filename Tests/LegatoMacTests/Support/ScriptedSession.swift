import Foundation
import LegatoCore

/// A scripted rolling `LLMSession`: each turn gets the next reply (the request echoed once the script runs out:
/// "no change"); usage is characters / 4. `onRespond` runs while the "model" thinks (the user types meanwhile).
actor ScriptedSession: LLMSession {
    nonisolated let tokenBudget: Int
    private var replies: [String]
    private var historyChars = 0
    private(set) var requests: [String] = []
    private(set) var appended: [LLMSessionChunk] = []
    private let onRespond: (@MainActor @Sendable () -> Void)?

    init(budget: Int = 4_000, replies: [String], onRespond: (@MainActor @Sendable () -> Void)? = nil) {
        tokenBudget = budget
        self.replies = replies
        self.onRespond = onRespond
    }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: (historyChars + 3) / 4) }

    func append(_ chunk: LLMSessionChunk) async throws { appended.append(chunk) }

    func respond(to request: String) async throws -> String {
        requests.append(request)
        historyChars += request.count
        if let onRespond { await onRespond() }
        let reply = replies.isEmpty ? request : replies.removeFirst()
        historyChars += reply.count
        return reply
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        throw LLMSessionError.invalidStructuredOutput("the agent asks for plain text")
    }

    func trim(keepingSuffix tokens: Int) async throws { historyChars = min(historyChars, tokens * 4) }
    func warm() async throws {}
    func close() async {}
}
