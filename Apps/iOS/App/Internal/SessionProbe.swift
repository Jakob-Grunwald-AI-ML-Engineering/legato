#if LEGATO_INTERNAL
import Foundation
import LegatoAppServices
import LegatoCore
import LegatoCoreML
import LegatoPostProcessing
import UIKit
import os

enum SessionProbeMode: String, Sendable, CaseIterable {
    /// Runs now, in whatever state the app is in.
    case foreground
    /// Prepares the models now, waits until the app is in the background (up to 3 minutes), then runs under
    /// a background task (about 30 s once in the background).
    case background
    /// Like `background`, with the microphone kept ready first (the keyboard's `arm` lease: the dictation
    /// audio session, no run, no history entry), which keeps the app running in the background as during a
    /// real dictation's cleanup. The lease ends with the probe.
    case backgroundAudio = "background-audio"
    /// The continuous cleanup agent (spike #95): one Core ML or MLX CPU model, a 2–3 min stream of chunks at
    /// speech pace into one warm session; see ``SessionProbe/runContinuous(models:)``. Configured by the
    /// `LEGATO_PROBE_*` environment, never by the other modes' backends.
    case continuous
}

/// ## Running
///
/// Continuous cleanup agent (spike #95, mode `continuous`, ContinuousProbe.swift): one backend × model per
/// launch, Foundation Models never. Install a Debug device build first (this branch has no
/// `scripts/device/ctl.sh`; use main's, or `xcodebuild build -project Apps/iOS/Legato.xcodeproj -scheme Legato
/// -configuration Debug -destination id=$D -allowProvisioningUpdates` after `xcodegen generate` in Apps/iOS,
/// then `xcrun devicectl device install app --device $D <Legato.app>`). For MLX CPU numbers add
/// `GCC_OPTIMIZATION_LEVEL=3 SWIFT_OPTIMIZATION_LEVEL=-O` to that xcodebuild: Debug compiles MLX's C++ CPU
/// kernels at -O0 (Core ML runs on the Neural Engine and is unaffected). A launch downloads a missing model in
/// the foreground (logged), loads it, arms the microphone, waits up to 3 min for the background (press Home)
/// and replays the annotated corpus (ContinuousAgentCorpus.swift: 562 words, 70 mistakes, ~225 s at 2.5 words/s)
/// twice on fresh sessions: one launch takes about 9 min plus the load (`LEGATO_PROBE_REPEATS=3` and
/// `LEGATO_PROBE_WARM=1`, a further pass on the last session, add ~3.75 min each). Set the keep-ready linger in
/// Settings to at least 15 min. devicectl parses dash-prefixed arguments as its own, so the configuration goes
/// in the environment:
///
///     D=00008150-000E60360245401C
///     xcrun devicectl device process launch --device $D --terminate-existing --environment-variables '{"LEGATO_SESSION_PROBE":"continuous","LEGATO_PROBE_BACKEND":"coreml","LEGATO_PROBE_MODEL":"qwen3-1.7b","LEGATO_PROBE_BG":"audio"}' de.gruenwald.legato
///     xcrun devicectl device process launch --device $D --terminate-existing --environment-variables '{"LEGATO_SESSION_PROBE":"continuous","LEGATO_PROBE_BACKEND":"mlx-cpu","LEGATO_PROBE_MODEL":"qwen3-1.7b","LEGATO_PROBE_BG":"audio"}' de.gruenwald.legato
///     xcrun devicectl device process launch --device $D --terminate-existing --environment-variables '{"LEGATO_SESSION_PROBE":"continuous","LEGATO_PROBE_BACKEND":"coreml","LEGATO_PROBE_MODEL":"qwen3-0.6b","LEGATO_PROBE_BG":"audio"}' de.gruenwald.legato
///     xcrun devicectl device process launch --device $D --terminate-existing --environment-variables '{"LEGATO_SESSION_PROBE":"continuous","LEGATO_PROBE_BACKEND":"mlx-cpu","LEGATO_PROBE_MODEL":"qwen3-0.6b","LEGATO_PROBE_BG":"audio"}' de.gruenwald.legato
///
/// `LEGATO_PROBE_BG`: `audio` (microphone lease + background task: the measured case), `none` (background task
/// only; iOS suspends after ~30 s), `foreground` (no wait, no lease). Optional: `LEGATO_PROBE_WPS` (2.5),
/// `LEGATO_PROBE_REPEATS` (2), `LEGATO_PROBE_WARM` (0), `LEGATO_PROBE_SEED` (95; run r uses seed + r - 1),
/// `LEGATO_PROBE_WINDOW` (1000 context tokens, the same for every backend). Rewrite mode (ContinuousRewriteProbe.swift):
/// `LEGATO_PROBE_MODE=rewrite` (default `edits`), `LEGATO_PROBE_LAYOUT` (`onepass`, `turns`), `LEGATO_PROBE_CTX_PCT`
/// (25: the share of the model's real window, 2048 for Core ML 1.7B, 4096 otherwise, every request stays within),
/// `LEGATO_PROBE_PAUSE_MS` (700) and `LEGATO_PROBE_MAX_WORDS` (30) for the endpointer. Results go to
/// `Library/Caches/continuous-probe.jsonl` (append-only) and audio-diag.jsonl (restarts at 1 MB):
///
///     xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier de.gruenwald.legato \
///       --source Library/Caches/continuous-probe.jsonl --destination ./continuous-probe.jsonl
///
/// Events `session.probe.continuous.<x>`: `start`, `download`, `load`, `arm`, `background`, `warm`, `turn` (one
/// per chunk: compute ms, prefill/ttft/decode, keptUp, reply, fixed mistakes, wrong edits), `trim`, `mistake`
/// (one per annotated mistake and run: kind, type, tags, appearChunk, fixedChunk, latencyMs), `run` (per-run
/// figures), `summary` (fresh runs pooled: local/sentence latency mean/median/p95/sd, fixed k/n, wrong edits k/n,
/// turn ms, keep-up, peak memory, thermal, battery), `summary.warm`, `breakdown` (per tag, type, passage),
/// `thermal`, `memoryWarning`, `stop`, `memory`, `done`. Every line carries `backend`, `model`, `bg`, `appState`.
///
/// Device measurement of persistent LLM sessions (epic #80), internal builds only. For Foundation Models and
/// the selected Core ML cleanup model: turn 1 (instructions + ~800 tokens of text), turn 2 (+~40 tokens) on
/// the same session, the same turn 2 on a fresh session (history given as an example turn), and a warm
/// kickstart (a new run on a session whose head was prewarmed ahead) against a cold one. Both kickstarts
/// start after the same idle gap, so an asynchronous prewarm (Foundation Models) has had time to finish.
///
/// Every step logs a `session.probe` line to ``AudioDiagnostics`` (`Library/Caches/audio-diag.jsonl`):
/// `backend`, `turn`, `promptChars`, `promptTokens` / `prefilledTokens` / `prefillMs` where the backend
/// reports them, `wallMs`, `replyEqual` for the fresh turn, the run `mode`, `appState` and, in the
/// background, `backgroundTimeRemainingS`. Never text. `session.probe.done` closes a run.
///
/// Triggers: the Debug buttons in Settings, or the environment (devicectl parses dash-prefixed launch
/// arguments as its own options):
///
///     xcrun devicectl device process launch --device <device> --terminate-existing \
///       --environment-variables '{"LEGATO_SESSION_PROBE":"foreground"}' de.gruenwald.legato
///       # or: background, background-audio
///
/// One entry point (``run(mode:delay:models:)``) for every trigger.
@MainActor enum SessionProbe {
    static var running = false
    static var mode = SessionProbeMode.foreground
    private static let kickstartGap = Duration.seconds(2)
    /// Memory warnings seen during this run (the load summaries report how many arrived during a load).
    static var warnings = 0

    /// Where each step is announced to the person holding the phone (the debug overlay's status banner in
    /// builds with the device bridge); nil text clears it. Unset, steps only reach the diagnostics log.
    static var announce: (@MainActor (String?) -> Void)?
    /// Turned on while the probe runs and off when it ends: the debug overlay blocks taps on the app below,
    /// so a stray tap cannot start a dictation mid-measurement.
    static var block: (@MainActor (Bool) -> Void)?

    /// Starts a probe without waiting for it (a bridge command must return while the probe runs).
    /// False when a probe is already running.
    @discardableResult
    static func start(mode: SessionProbeMode, ignoreMemoryWarnings: Bool = false, models: ModelServices) -> Bool {
        guard !running else { return false }
        Task { await run(mode: mode, ignoreMemoryWarnings: ignoreMemoryWarnings, models: models) }
        return true
    }

    static func say(_ text: String) { announce?("Session probe (\(mode.rawValue)): \(text)") }

    static func brief(_ error: any Error) -> String { String((error as NSError).localizedDescription.prefix(120)) }

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

    /// `ignoreMemoryWarnings`: for this run, a memory warning releases nothing in the app (it is only logged),
    /// to measure whether the Core ML load survives the warning.
    static func run(mode: SessionProbeMode, delay: Duration = .zero, ignoreMemoryWarnings: Bool = false, models: ModelServices) async {
        guard !running else { return }
        if mode == .continuous { await runContinuous(models: models); return }
        running = true; warnings = 0
        self.mode = mode
        block?(true)
        defer { running = false; block?(false) }
        // A background run holds its background task from the start, before any suspension: iOS suspends an
        // app soon after it leaves the foreground, before a task begun on noticing the background would run.
        let keepAlive = mode == .foreground ? nil : BackgroundTask(mode: mode)
        defer { keepAlive?.end() }
        let memory = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { warnings += 1; _ = logMemory("memoryWarning"); say("memory warning received") } }
        defer { NotificationCenter.default.removeObserver(memory) }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler {
            let event = pressure.data
            MainActor.assumeIsolated { logMemory("pressure", ["level": event.contains(.critical) ? "critical" : "warning"]) }
        }
        pressure.activate()
        defer { pressure.cancel() }
        AudioDiagnostics.log("session.probe.start", ["mode": mode.rawValue, "delayS": delay.components.seconds,
                                                     "ignoreMemoryWarnings": ignoreMemoryWarnings, "appState": appState])

        // Only the probe's models in memory: the keep-ready microphone ends and the app's warm speech and
        // cleanup models are released (and kept released) until the probe ends; then they prepare again.
        say("releasing the app's own models")
        let beforeRelease = logMemory("beforeRelease")
        await AppController.shared.releaseModelsForProbe()
        AppController.shared.probeIgnoresMemoryWarnings = ignoreMemoryWarnings
        try? await Task.sleep(for: .seconds(1))
        let afterRelease = logMemory("afterRelease", ["freedMB": beforeRelease.footprintMB - Memory.now().footprintMB])
        say("app models released (\(Int(beforeRelease.footprintMB - afterRelease.footprintMB)) MB freed); preparing models\(ignoreMemoryWarnings ? ", ignoring memory warnings" : "")")

        // Prepare in the foreground: a background start may not load models.
        var backends: [(name: String, backend: any LLMBackend)] = []
        if await FoundationModelsBackend().availability.isAvailable {
            backends.append(("foundation-models", FoundationModelsBackend()))
        } else {
            log(backend: "foundation-models", turn: "skipped", ["reason": "unavailable"])
        }
        if let id = models.selected(.cleanup), let spec = CoreMLModels.spec(id: id) {
            if let coreML = await prepare(spec, name: "coreml:\(id)", models: models) { backends.append(("coreml:\(id)", coreML)) }
        } else {
            log(backend: "coreml", turn: "skipped", ["reason": "no Core ML cleanup model selected"])
        }

        if mode == .backgroundAudio {
            let armed = await AppController.shared.perform(.arm)
            log(backend: "app", turn: "arm", ["armed": armed])
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if mode != .foreground {
            say("models ready; waiting for the app to go to the background")
            let deadline = ContinuousClock.now + .seconds(180)
            while UIApplication.shared.applicationState != .background, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            log(backend: "app", turn: "background", ["keepAlive": mode == .backgroundAudio ? "microphoneLease+backgroundTask" : "backgroundTask"])
        }

        var failures = 0
        for (name, backend) in backends {
            say("measuring \(name)")
            do { try await measure(backend, name: name) } catch {
                failures += 1
                log(backend: name, turn: "failed", ["error": AudioDiagnostics.describe(error)])
                say("\(name) failed: \(brief(error))")
            }
        }
        AudioDiagnostics.log("session.probe.done", ["mode": mode.rawValue, "ok": failures == 0, "backends": backends.map(\.name), "appState": appState])
        logMemory("end")
        // The app prepares its own models again (speech and cleanup together): sample that load as well.
        say("restoring the app's own models")
        let restore = LoadSampler(phase: "restore")
        restore.start()
        await AppController.shared.endProbeHold()
        restore.stop()
        logMemory("afterRestore", restore.summary.merging(["ready": AppController.shared.status.isReady, "recognitionPreparing": AppController.shared.recognitionPreparing]) { $1 })
        say("done (\(failures == 0 ? "ok" : "\(failures) failed"); measured: \(backends.map(\.name).joined(separator: ", ")))")
        if mode == .backgroundAudio { await AppController.shared.endKeepAlive() }
    }

    /// Prepares the Core ML backend the app's own warmup shares. A launch-time release (memory pressure, a
    /// selection change) cancels a preparation in flight with `CancellationError`; the probe logs what the
    /// app's preparation status was and tries again, up to three times. Each attempt asks the store for the
    /// backend again: a release retires the old owner, and preparing that one would load a second copy.
    private static func prepare(_ spec: CoreMLModelSpec, name: String, models: ModelServices) async -> CoreMLBackend? {
        for attempt in 1...3 {
            let start = ContinuousClock.now
            say("preparing \(name) (attempt \(attempt) of 3)")
            let coreML = await CoreMLModelStore.shared.backend(for: spec, root: ModelServices.phoneModelsRoot)
            logMemory("beforeLoad", ["attempt": attempt])
            let sampler = LoadSampler()
            sampler.start()
            defer { sampler.stop() }
            do {
                try await coreML.prepare()
                sampler.stop()
                logMemory("afterLoad", sampler.summary.merging(["attempt": attempt, "completed": true]) { $1 })
                // The app's own rolling session warms on the same single native worker; let it finish first.
                let rolling = await models.rollingCleanupSession(for: .coreML)
                log(backend: name, turn: "prepared", ["attempt": attempt, "wallMs": ms(ContinuousClock.now - start), "rollingSession": rolling != nil])
                say("\(name) prepared in \(ms(ContinuousClock.now - start)) ms")
                return coreML
            } catch {
                sampler.stop()
                logMemory("afterLoad", sampler.summary.merging(["attempt": attempt, "completed": false]) { $1 })
                log(backend: name, turn: attempt < 3 ? "prepare.retry" : "skipped", [
                    "reason": "prepare failed", "attempt": attempt, "error": AudioDiagnostics.describe(error),
                    "errorType": String(describing: type(of: error)), "wallMs": ms(ContinuousClock.now - start),
                    "appPreparation": String(describing: models.cleanupPreparation.state),
                    "prepared": await coreML.isPrepared(),
                ])
                say("\(name) prepare attempt \(attempt) failed: \(brief(error))")
                if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        return nil
    }

    /// A probe-only keep-alive. Its expiry ends the task (iOS terminates an app that lets one run out).
    @MainActor final class BackgroundTask {
        private var id = UIBackgroundTaskIdentifier.invalid
        init(mode: SessionProbeMode) {
            id = UIApplication.shared.beginBackgroundTask(withName: "session.probe") { [weak self] in
                MainActor.assumeIsolated {
                    AudioDiagnostics.log("session.probe.expired", ["mode": mode.rawValue, "appState": SessionProbe.appState])
                    self?.end()
                }
            }
        }
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    // MARK: Memory

    /// The process footprint (what jetsam counts) and what iOS says is left before the limit.
    struct Memory {
        var footprintMB: Double
        var availableMB: Double
        static func now() -> Memory {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            let footprint = status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
            return Memory(footprintMB: footprint, availableMB: Double(os_proc_available_memory()) / 1_048_576)
        }
        var fields: [String: Any] { ["footprintMB": Int(footprintMB), "availableMB": Int(availableMB)] }
    }

    /// One `session.probe.memory` line: `phase`, footprint and available memory, plus `fields`.
    @discardableResult
    static func logMemory(_ phase: String, _ fields: [String: Any] = [:]) -> Memory {
        let memory = Memory.now()
        var line = memory.fields.merging(fields) { $1 }
        line["phase"] = phase; line["mode"] = mode.rawValue; line["appState"] = appState
        AudioDiagnostics.log("session.probe.memory", line)
        return memory
    }

    /// Samples memory every 250 ms during a Core ML load (logged as phase `load`), keeping the peak footprint
    /// and the least available memory seen.
    @MainActor private final class LoadSampler {
        private var task: Task<Void, Never>?
        private var peakFootprint = 0.0
        private var minAvailable = Double.greatestFiniteMagnitude
        private var samples = 0
        private let started = ContinuousClock.now
        private let phase: String
        private let warningsAtStart = SessionProbe.warnings
        init(phase: String = "load") { self.phase = phase }

        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        /// Samples every 250 ms; logs every 8th (2 s), since the diagnostics file restarts at 1 MB.
        private func sample(force: Bool = false) {
            let memory: Memory
            if force || samples % 8 == 0 {
                memory = SessionProbe.logMemory(phase, ["elapsedMs": SessionProbe.ms(ContinuousClock.now - started)])
            } else {
                memory = Memory.now()
            }
            peakFootprint = max(peakFootprint, memory.footprintMB)
            minAvailable = min(minAvailable, memory.availableMB)
            samples += 1
        }
        func stop() {
            guard let task else { return }
            task.cancel(); self.task = nil
            sample(force: true)
        }
        var summary: [String: Any] {
            ["peakFootprintMB": Int(peakFootprint), "minAvailableMB": Int(minAvailable), "samples": samples,
             "memoryWarnings": SessionProbe.warnings - warningsAtStart,
             "loadMs": SessionProbe.ms(ContinuousClock.now - started)]
        }
    }

    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    // MARK: Measurement

    private static let instructions = "You answer questions about the harbour log in at most eight words."
    private static func sentences(_ range: ClosedRange<Int>) -> String {
        range.map { "\($0): The harbour master logged boat number \($0) arriving with a cargo of timber and rope." }
            .joined(separator: "\n")
    }

    private static func measure(_ backend: any LLMBackend, name: String) async throws {
        let context = sentences(1...40)  // ~800 tokens
        let request1 = "Which cargo did boat 3 bring?"
        let addition = "\n41: The ferry to the island leaves at noon.\n42: The pilot boat waits at the north pier."  // ~40 tokens
        let request2 = "When does the ferry leave?"

        let session = try await backend.makeSession()
        defer { Task { await session.close() } }
        try await session.append(.instructions(instructions))
        try await session.append(.text(context))
        let reply1 = try await timed(session, name, turn: "1", chars: instructions.count + context.count + request1.count) {
            try await session.respond(to: request1)
        }
        try await session.append(.text(addition))
        let reply2 = try await timed(session, name, turn: "2", chars: addition.count + request2.count) {
            try await session.respond(to: request2)
        }

        let fresh = try await backend.makeSession()
        defer { Task { await fresh.close() } }
        try await fresh.append(.instructions(instructions))
        try await fresh.append(.example(LLMExample(user: context + "\n\n" + request1, assistant: reply1)))
        try await fresh.append(.text(addition))
        let replay = try await timed(fresh, name, turn: "2.fresh", chars: instructions.count + context.count + reply1.count + addition.count) {
            try await fresh.respond(to: request2)
        } extra: { ["replyEqual": $0 == reply2] }
        _ = replay

        // Foundation Models loads fast; only slow-loading models need a kickstart measurement (Jakob, epic #80).
        guard !(backend is FoundationModelsBackend) else { return }

        // Warm kickstart: the head (instructions + ~400 tokens) prefilled ahead, then a new run's first turn.
        let head = instructions + "\n" + sentences(1...20)
        let run = "[run 2]\n" + sentences(21...22)
        let warm = try await backend.makeSession()
        defer { Task { await warm.close() } }
        try await warm.append(.instructions(head))
        let warmStart = ContinuousClock.now
        try await warm.warm()
        log(backend: name, turn: "kickstart.head", metrics(await (warm as? any LLMSessionMetrics)?.lastWarmMetrics())
            .merging(["promptChars": head.count, "wallMs": ms(ContinuousClock.now - warmStart)]) { $1 })
        try? await Task.sleep(for: kickstartGap)
        try await warm.append(.text(run))
        _ = try await timed(warm, name, turn: "kickstart.warm", chars: run.count) { try await warm.respond(to: "Which cargo did boat 22 bring?") }

        // The same with the run's text known ahead: Foundation Models prewarms it as the prompt prefix.
        let prefixed = try await backend.makeSession()
        defer { Task { await prefixed.close() } }
        try await prefixed.append(.instructions(head))
        try await prefixed.append(.text(run))
        try await prefixed.warm()
        try? await Task.sleep(for: kickstartGap)
        _ = try await timed(prefixed, name, turn: "kickstart.warmPrefix", chars: run.count) { try await prefixed.respond(to: "Which cargo did boat 22 bring?") }

        let cold = try await backend.makeSession()
        defer { Task { await cold.close() } }
        try await cold.append(.instructions(head))
        try? await Task.sleep(for: kickstartGap)
        try await cold.append(.text(run))
        _ = try await timed(cold, name, turn: "kickstart.cold", chars: head.count + run.count) { try await cold.respond(to: "Which cargo did boat 22 bring?") }
    }

    private static func timed(_ session: any LLMSession, _ name: String, turn: String, chars: Int,
                              _ body: () async throws -> String,
                              extra: (String) -> [String: Any] = { _ in [:] }) async throws -> String {
        let start = ContinuousClock.now
        let reply = try await body()
        let wall = ContinuousClock.now - start
        var fields = metrics(await (session as? any LLMSessionMetrics)?.lastTurnMetrics())
        fields["promptChars"] = chars
        fields["wallMs"] = ms(wall)
        fields.merge(extra(reply)) { $1 }
        log(backend: name, turn: turn, fields)
        say("\(name) turn \(turn): \(ms(wall)) ms")
        return reply
    }

    private static func metrics(_ metrics: LLMTurnMetrics?) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let tokens = metrics?.promptTokens { fields["promptTokens"] = tokens }
        if let tokens = metrics?.prefilledTokens { fields["prefilledTokens"] = tokens }
        if let seconds = metrics?.prefillSeconds { fields["prefillMs"] = Int(seconds * 1_000) }
        return fields
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func log(backend: String, turn: String, _ fields: [String: Any] = [:]) {
        var fields = fields.merging(["mode": mode.rawValue, "backend": backend, "turn": turn, "appState": appState]) { $1 }
        if UIApplication.shared.applicationState == .background {
            fields["backgroundTimeRemainingS"] = Int(min(UIApplication.shared.backgroundTimeRemaining, 9_999))
        }
        AudioDiagnostics.log("session.probe", fields)
    }
}
#endif
