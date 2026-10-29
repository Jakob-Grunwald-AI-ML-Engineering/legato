import Foundation
import LegatoCore

/// A scripted rolling `LLMSession`: each structured request gets the next reply (`[]` once the script runs
/// out); usage is characters / 4. `onRespond` runs while the "model" thinks (the user types meanwhile).
actor ScriptedSession: LLMSession {
    nonisolated let tokenBudget: Int
    private var replies: [String]
    private var historyChars = 0
    private(set) var requests: [String] = []
    private(set) var appended: [String] = []
    private let onRespond: (@MainActor @Sendable () -> Void)?

    init(budget: Int = 4_000, replies: [String], onRespond: (@MainActor @Sendable () -> Void)? = nil) {
        tokenBudget = budget
        self.replies = replies
        self.onRespond = onRespond
    }

    /// `[{"sentence":n,"text":"…"}]` for the given rewrites.
    static func edits(_ pairs: (Int, String)...) -> String {
        "[" + pairs.map { #"{"sentence":\#($0.0),"text":"\#($0.1)"}"# }.joined(separator: ",") + "]"
    }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: (historyChars + 3) / 4) }

    func append(_ chunk: LLMSessionChunk) async throws {
        if case .text(let text) = chunk {
            appended.append(text)
            historyChars += text.count
        }
    }

    func respond(to request: String) async throws -> String { "" }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        requests.append(request)
        historyChars += request.count
        if let onRespond { await onRespond() }
        let reply = replies.isEmpty ? "[]" : replies.removeFirst()
        return try LLMStructuredDecoding.decode(Output.self, from: reply)
    }

    func trim(keepingSuffix tokens: Int) async throws { historyChars = min(historyChars, tokens * 4) }
    func warm() async throws {}
    func close() async {}
}
