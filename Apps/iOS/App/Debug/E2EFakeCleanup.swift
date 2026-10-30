#if DEBUG
import Foundation
import LegatoAppServices
import LegatoCore
import LegatoFieldEdit
import LegatoPostProcessing
import Synchronization

/// Scripted cleanup for the simulator end-to-end run (`scripts/e2e/ios-sim.sh`, scenario fa): the simulator has
/// no cleanup model. Debug builds only.
///
/// Launch arguments:
/// - `-LegatoFakeCleanup "teh=the,dgo=dog"`: whole-word replacements. The session's rewrite at stop (a run without
///   a keyboard field, a run whose agent was absent) applies them, and so does the cleanup agent's rolling session
///   (`E2EFakeAgentSession`), sentence by sentence or the whole dictation at a Replace stop.
/// - `-LegatoFakeAgent NO`: no rolling session for the agent (it is absent; the stop rewrites the text instead).
/// - `-LegatoFakeAgentDelayMs <n>`: every agent turn takes this long (default 0).
/// - `-LegatoCleanupDelivery live|replace`: cleanup on, with that delivery (an older build's hold or clipboard
///   reads as live).
extension E2E {
    static let fakeCleanupRules: [(String, String)]? = {
        guard let spec = UserDefaults.standard.string(forKey: "LegatoFakeCleanup"), !spec.isEmpty else { return nil }
        return spec.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }()

    static let fakeCleanup: E2EFakeCleanup? = fakeCleanupRules.map(E2EFakeCleanup.init)

    /// The rolling session the fake agent runs on; `session` nil with `-LegatoFakeAgent NO`.
    struct FakeAgent: Sendable {
        let session: (any LLMSession)?
    }

    private static let fakeAgentSession: (any LLMSession)? = fakeCleanupRules.map {
        E2EFakeAgentSession(rules: $0, delay: .milliseconds(UserDefaults.standard.integer(forKey: "LegatoFakeAgentDelayMs")))
    }

    /// Nil when the fake cleanup is off (the real rolling session is used).
    static func makeFakeAgentSession() -> FakeAgent? {
        guard fakeCleanupRules != nil else { return nil }
        let absent = UserDefaults.standard.string(forKey: "LegatoFakeAgent").map { ["NO", "FALSE", "0"].contains($0.uppercased()) } ?? false
        return FakeAgent(session: absent ? nil : fakeAgentSession)
    }

    /// Agent turns in flight (the harness waits for one before it types into the run's text).
    static let agentAsksInFlight = Mutex(0)

    @MainActor
    static func applyCleanupLaunchSettings() {
        if let raw = UserDefaults.standard.string(forKey: "LegatoCleanupDelivery"), let delivery = CleanupDelivery(stored: raw) {
            Settings.cleanupEnabled = true
            Settings.cleanupDelivery = delivery
        }
        if fakeCleanupRules != nil {
            log("cleanup.settings enabled=\(Settings.cleanupEnabled ? 1 : 0) delivery=\(Settings.cleanupDelivery.rawValue) fake=1")
        }
    }

    /// `text` with every rule applied to whole words.
    static func applyRules(_ rules: [(String, String)], to text: String) -> String {
        var out = text
        for (from, to) in rules {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return out
    }
}

/// The session's cleanup, scripted: one whole-text pass at the stop.
struct E2EFakeCleanup: TranscriptPostProcessor {
    let rules: [(String, String)]
    var id: String { "e2e-cleanup" }

    func process(_ text: String, locale: Locale) async throws -> String {
        let out = E2E.applyRules(rules, to: text)
        E2E.log("cleanup.pass changed=\(out != text ? 1 : 0)")
        CleanupCallTrace.emit("cleanup.call", ["kind": CleanupCallTrace.kind, "backend": "e2e-fake", "ms": "0"])
        return out
    }
}

/// The cleanup agent's rolling session, scripted: each turn answers its sentence (or, closed by the final request,
/// its whole dictation) with the rules applied.
actor E2EFakeAgentSession: LLMSession {
    nonisolated let tokenBudget = 4_000
    private let rules: [(String, String)]
    private let delay: Duration
    private var characters = 0
    private var asks = 0

    init(rules: [(String, String)], delay: Duration) {
        self.rules = rules
        self.delay = delay
    }

    func usage() async throws -> LLMTokenUsage { LLMTokenUsage(head: 0, history: characters / 4) }

    func append(_ chunk: LLMSessionChunk) async throws {}

    func respond(to request: String) async throws -> String {
        asks += 1
        let n = asks
        characters += request.count
        let suffix = "\n\n" + CleanupPrompt.Agent.finalRequestLine
        let final = request.hasSuffix(suffix)
        let text = final ? String(request.dropLast(suffix.count)) : request
        E2E.log("agent.ask n=\(n) final=\(final ? 1 : 0) words=\(text.split(separator: " ").count)")
        E2E.agentAsksInFlight.withLock { $0 += 1 }
        defer { E2E.agentAsksInFlight.withLock { $0 -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        let cleaned = E2E.applyRules(rules, to: text)
        E2E.log("agent.reply n=\(n) changed=\(cleaned != text ? 1 : 0)")
        characters += cleaned.count
        return cleaned
    }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        throw LLMSessionError.invalidStructuredOutput("the agent asks for plain text")
    }

    func trim(keepingSuffix tokens: Int) async throws { characters = min(characters, tokens * 4) }
    func warm() async throws {}
    func close() async {}
}
#endif
