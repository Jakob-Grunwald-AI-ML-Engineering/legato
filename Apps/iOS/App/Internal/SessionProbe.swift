#if LEGATO_INTERNAL
import Foundation
import LegatoAppServices
import LegatoCore
import LegatoCoreML
import LegatoPostProcessing
import UIKit

enum SessionProbeMode: String, Sendable, CaseIterable {
    /// Runs now, in whatever state the app is in.
    case foreground
    /// Prepares the models now, waits until the app is in the background (up to 3 minutes), then runs under
    /// a background task.
    case background
}

/// Device measurement of persistent LLM sessions (epic #80), internal builds only. For Foundation Models and
/// the selected Core ML cleanup model: turn 1 (instructions + ~800 tokens of text), turn 2 (+~40 tokens) on
/// the same session, the same turn 2 on a fresh session (history given as an example turn), and a warm
/// kickstart (a new run on a session whose head was prefilled ahead) against a cold one.
///
/// Every step logs a `session.probe` line to ``AudioDiagnostics`` (`Library/Caches/audio-diag.jsonl`):
/// `backend`, `turn`, `promptChars`, `promptTokens` / `prefilledTokens` / `prefillMs` where the backend
/// reports them, `wallMs`, `replyEqual` for the fresh turn, the run `mode` and the app state. Never text.
/// `session.probe.done` closes a run.
///
/// Triggers: the Debug buttons in Settings, or a launch argument / environment variable:
///
///     xcrun devicectl device process launch --device <device> --terminate-existing \
///       de.gruenwald.legato -LegatoSessionProbe foreground      # or: background
///
/// One entry point (``run(mode:delay:models:)``) for every trigger.
@MainActor enum SessionProbe {
    private static var running = false

    /// Starts a probe when the launch arguments (`-LegatoSessionProbe <mode>`) or the environment
    /// (`LEGATO_SESSION_PROBE=<mode>`) ask for one.
    static func runIfRequested(models: ModelServices) {
        let arguments = ProcessInfo.processInfo.arguments
        let value = arguments.firstIndex(of: "-LegatoSessionProbe").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["LEGATO_SESSION_PROBE"]
        guard let value else { return }
        guard let mode = SessionProbeMode(rawValue: value) else {
            AudioDiagnostics.log("session.probe.done", ["ok": false, "error": "unknown mode \(value)"])
            return
        }
        Task { await run(mode: mode, models: models) }
    }

    static func run(mode: SessionProbeMode, delay: Duration = .zero, models: ModelServices) async {
        guard !running else { return }
        running = true
        defer { running = false }
        AudioDiagnostics.log("session.probe.start", ["mode": mode.rawValue, "delayS": delay.components.seconds])

        // Prepare in the foreground: a background start may not load models.
        var backends: [(name: String, backend: any LLMBackend)] = []
        if await FoundationModelsBackend().availability.isAvailable {
            backends.append(("foundation-models", FoundationModelsBackend()))
        } else {
            log(mode, backend: "foundation-models", turn: "skipped", ["reason": "unavailable"])
        }
        if let id = models.selected(.cleanup), let spec = CoreMLModels.spec(id: id) {
            let coreML = await CoreMLModelStore.shared.backend(for: spec, root: ModelServices.phoneModelsRoot)
            do {
                try await coreML.prepare()
                // The app's own rolling session warms on the same single native worker; let it finish first.
                _ = await models.rollingCleanupSession(for: .coreML)
                backends.append(("coreml:\(id)", coreML))
            } catch {
                log(mode, backend: "coreml:\(id)", turn: "skipped", ["reason": "prepare failed", "error": AudioDiagnostics.describe(error)])
            }
        } else {
            log(mode, backend: "coreml", turn: "skipped", ["reason": "no Core ML cleanup model selected"])
        }

        if delay > .zero { try? await Task.sleep(for: delay) }
        var task = UIBackgroundTaskIdentifier.invalid
        if mode == .background {
            let deadline = ContinuousClock.now + .seconds(180)
            while UIApplication.shared.applicationState != .background, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Probe-only keep-alive: a background task (about 30 s). Real background cleanup runs while the
            // dictation's audio session keeps the app alive; this probe holds no audio session.
            task = UIApplication.shared.beginBackgroundTask(withName: "session.probe") {
                AudioDiagnostics.log("session.probe.expired", ["mode": mode.rawValue])
            }
            log(mode, backend: "app", turn: "background", ["keepAlive": "backgroundTask",
                "backgroundTimeRemainingS": UIApplication.shared.backgroundTimeRemaining])
        }

        var failures = 0
        for (name, backend) in backends {
            do { try await measure(backend, name: name, mode: mode) } catch {
                failures += 1
                log(mode, backend: name, turn: "failed", ["error": AudioDiagnostics.describe(error)])
            }
        }
        AudioDiagnostics.log("session.probe.done", ["mode": mode.rawValue, "ok": failures == 0, "backends": backends.map(\.name)])
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    // MARK: Measurement

    private static let instructions = "You answer questions about the harbour log in at most eight words."
    private static func sentences(_ range: ClosedRange<Int>) -> String {
        range.map { "\($0): The harbour master logged boat number \($0) arriving with a cargo of timber and rope." }
            .joined(separator: "\n")
    }

    private static func measure(_ backend: any LLMBackend, name: String, mode: SessionProbeMode) async throws {
        let context = sentences(1...40)  // ~800 tokens
        let request1 = "Which cargo did boat 3 bring?"
        let addition = "\n41: The ferry to the island leaves at noon.\n42: The pilot boat waits at the north pier."  // ~40 tokens
        let request2 = "When does the ferry leave?"

        let session = try await backend.makeSession()
        defer { Task { await session.close() } }
        try await session.append(.instructions(instructions))
        try await session.append(.text(context))
        let reply1 = try await timed(session, mode, name, turn: "1", chars: instructions.count + context.count + request1.count) {
            try await session.respond(to: request1)
        }
        try await session.append(.text(addition))
        let reply2 = try await timed(session, mode, name, turn: "2", chars: addition.count + request2.count) {
            try await session.respond(to: request2)
        }

        let fresh = try await backend.makeSession()
        defer { Task { await fresh.close() } }
        try await fresh.append(.instructions(instructions))
        try await fresh.append(.example(LLMExample(user: context + "\n\n" + request1, assistant: reply1)))
        try await fresh.append(.text(addition))
        let replay = try await timed(fresh, mode, name, turn: "2.fresh", chars: instructions.count + context.count + reply1.count + addition.count) {
            try await fresh.respond(to: request2)
        } extra: { ["replyEqual": $0 == reply2] }
        _ = replay

        // Warm kickstart: the head (instructions + ~400 tokens) prefilled ahead, then a new run's first turn.
        let head = instructions + "\n" + sentences(1...20)
        let run = "[run 2]\n" + sentences(21...22)
        let warm = try await backend.makeSession()
        defer { Task { await warm.close() } }
        try await warm.append(.instructions(head))
        let warmStart = ContinuousClock.now
        try await warm.warm()
        log(mode, backend: name, turn: "kickstart.head", metrics(await (warm as? any LLMSessionMetrics)?.lastWarmMetrics())
            .merging(["promptChars": head.count, "wallMs": ms(ContinuousClock.now - warmStart)]) { $1 })
        try await warm.append(.text(run))
        _ = try await timed(warm, mode, name, turn: "kickstart.warm", chars: run.count) { try await warm.respond(to: "Which cargo did boat 22 bring?") }

        let cold = try await backend.makeSession()
        defer { Task { await cold.close() } }
        try await cold.append(.instructions(head))
        try await cold.append(.text(run))
        _ = try await timed(cold, mode, name, turn: "kickstart.cold", chars: head.count + run.count) { try await cold.respond(to: "Which cargo did boat 22 bring?") }
    }

    private static func timed(_ session: any LLMSession, _ mode: SessionProbeMode, _ name: String, turn: String, chars: Int,
                              _ body: () async throws -> String,
                              extra: (String) -> [String: Any] = { _ in [:] }) async throws -> String {
        let start = ContinuousClock.now
        let reply = try await body()
        let wall = ContinuousClock.now - start
        var fields = metrics(await (session as? any LLMSessionMetrics)?.lastTurnMetrics())
        fields["promptChars"] = chars
        fields["wallMs"] = ms(wall)
        fields.merge(extra(reply)) { $1 }
        log(mode, backend: name, turn: turn, fields)
        return reply
    }

    private static func metrics(_ metrics: LLMTurnMetrics?) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let tokens = metrics?.promptTokens { fields["promptTokens"] = tokens }
        if let tokens = metrics?.prefilledTokens { fields["prefilledTokens"] = tokens }
        if let seconds = metrics?.prefillSeconds { fields["prefillMs"] = Int(seconds * 1_000) }
        return fields
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func log(_ mode: SessionProbeMode, backend: String, turn: String, _ fields: [String: Any] = [:]) {
        AudioDiagnostics.log("session.probe", fields.merging(["mode": mode.rawValue, "backend": backend, "turn": turn]) { $1 })
    }
}
#endif
