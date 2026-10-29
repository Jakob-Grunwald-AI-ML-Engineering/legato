#if DEBUG
import Foundation
import LegatoCore
import LegatoFieldEdit
import Synchronization

/// Scripted cleanup for the simulator end-to-end run (`scripts/e2e/ios-sim.sh`, scenario fa): the simulator has
/// no cleanup model. Debug builds only.
///
/// Launch arguments:
/// - `-LegatoFakeCleanup "teh=the,dgo=dog"`: whole-word replacements. The session's cleanup (its final pass, the
///   stateless pass of a run whose agent was absent) applies them; with the edit queue on, so does the cleanup
///   agent's rolling session (`E2EFakeAgentSession`), sentence by sentence.
/// - `-LegatoFakeAgent NO`: no rolling session (the agent is absent; the stop takes the stateless pass).
/// - `-LegatoFakeAgentDelayMs <n>`: every agent turn takes this long (default 0).
/// - `-LegatoCleanupDelivery live|replace|hold|clipboard`: cleanup on, with that delivery.
/// - `-LegatoFieldEditsSetting YES|NO`: the setting "Experimental: edit queue and cleanup agent".
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
        if let raw = UserDefaults.standard.string(forKey: "LegatoCleanupDelivery"), let delivery = CleanupDelivery(rawValue: raw) {
            Settings.cleanupEnabled = true
            Settings.cleanupDelivery = delivery
        }
        if let flag = UserDefaults.standard.string(forKey: "LegatoFieldEditsSetting") {
            Settings.fieldEdits = ["YES", "TRUE", "1"].contains(flag.uppercased())
        }
        if fakeCleanupRules != nil || UserDefaults.standard.object(forKey: "LegatoFieldEditsSetting") != nil {
            log("cleanup.settings enabled=\(Settings.cleanupEnabled ? 1 : 0) delivery=\(Settings.cleanupDelivery.rawValue) fieldEdits=\(Settings.fieldEdits ? 1 : 0) fake=\(fakeCleanupRules != nil ? 1 : 0)")
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
        return out
    }
}

/// The cleanup agent's rolling session, scripted: each turn answers the "Review" sentences the rules change.
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

    func append(_ chunk: LLMSessionChunk) async throws {
        guard case .text(let text) = chunk else { return }
        characters += text.count
        if text.contains("[conflict]") { E2E.log("agent.note conflict=1 user=\(text.contains(Conflict.userNoteMarker) ? 1 : 0)") }
        if text.contains("[field reset: cleared]") { E2E.log("agent.note reset=cleared") }
    }

    func respond(to request: String) async throws -> String { "" }

    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        asks += 1
        let n = asks
        characters += request.count
        var sentences: [Int: String] = [:]
        var review: [Int] = [], locked: [Int] = []
        for line in request.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Review: ") {
                review = Self.numbers(line.dropFirst("Review: ".count))
            } else if line.hasPrefix("Locked: ") {
                locked = Self.numbers(line.dropFirst("Locked: ".count))
            } else if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]) {
                sentences[number] = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        E2E.log("agent.ask n=\(n) sentences=\(sentences.count) review=\(review.map(String.init).joined(separator: ",")) locked=\(locked.map(String.init).joined(separator: ","))")
        E2E.agentAsksInFlight.withLock { $0 += 1 }
        defer { E2E.agentAsksInFlight.withLock { $0 -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        var edits: [String] = []
        for number in review {
            guard let text = sentences[number] else { continue }
            let cleaned = E2E.applyRules(rules, to: text)
            if cleaned != text { edits.append(#"{"sentence":\#(number),"text":"\#(cleaned)"}"#) }
        }
        E2E.log("agent.reply n=\(n) edits=\(edits.count)")
        return try LLMStructuredDecoding.decode(Output.self, from: "[" + edits.joined(separator: ",") + "]")
    }

    func trim(keepingSuffix tokens: Int) async throws { characters = min(characters, tokens * 4) }
    func warm() async throws {}
    func close() async {}

    private static func numbers(_ text: Substring) -> [Int] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "." }).compactMap { Int($0) }
    }
}

private extension Conflict {
    /// A phrase of the user note, to tell it in the session's context.
    static var userNoteMarker: String { "The user changed this text" }
}
#endif
