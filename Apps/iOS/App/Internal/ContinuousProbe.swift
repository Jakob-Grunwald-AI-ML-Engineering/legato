#if LEGATO_INTERNAL
import Foundation
import LegatoAppServices
import LegatoCore
import LegatoCoreML
import LegatoMLX
import LegatoModels
import UIKit

/// The probe's choices, from the launch environment (see ``SessionProbe`` `## Running`).
struct ContinuousProbeOptions: Sendable {
    enum Backend: String, Sendable { case coreml, mlxCPU = "mlx-cpu" }
    enum Model: String, Sendable { case qwen3_1_7b = "qwen3-1.7b", qwen3_0_6b = "qwen3-0.6b" }
    /// How the app is kept running: `audio` (the microphone lease plus a background task, as in a real
    /// dictation), `none` (a background task only: iOS suspends the app after about 30 s), `foreground`.
    enum Keep: String, Sendable { case audio, none, foreground }

    var backend: Backend
    var model: Model
    var keep: Keep
    var config: ProbeConfig

    struct Invalid: Error { var reason: String }

    static func from(_ environment: [String: String]) -> Result<ContinuousProbeOptions, Invalid> {
        let backend = environment["LEGATO_PROBE_BACKEND"] ?? "coreml"
        let model = environment["LEGATO_PROBE_MODEL"] ?? "qwen3-1.7b"
        let keep = environment["LEGATO_PROBE_BG"] ?? "audio"
        guard let b = Backend(rawValue: backend) else { return .failure(Invalid(reason: "unknown LEGATO_PROBE_BACKEND \(backend) (coreml, mlx-cpu)")) }
        guard let m = Model(rawValue: model) else { return .failure(Invalid(reason: "unknown LEGATO_PROBE_MODEL \(model) (qwen3-1.7b, qwen3-0.6b)")) }
        guard let k = Keep(rawValue: keep) else { return .failure(Invalid(reason: "unknown LEGATO_PROBE_BG \(keep) (audio, none, foreground)")) }
        var options = ContinuousProbeOptions(backend: b, model: m, keep: k, config: ProbeConfig(environment: environment, defaultRepeats: 2, defaultWarm: false))
        // Rewrite mode sizes its context share from the model's real window.
        options.config.contextWindow = b == .coreml ? options.coreMLSpec.runtimeConfiguration.contextLength : MLXBackend.contextWindow
        return .success(options)
    }

    var coreMLSpec: CoreMLModelSpec {
        CoreMLModels.spec(id: model == .qwen3_1_7b ? CoreMLModels.qwen3_1_7bID : CoreMLModels.qwen3_0_6bID)!
    }
    var mlxSpec: MLXModelSpec {
        MLXModels.spec(id: model == .qwen3_1_7b ? MLXModels.qwen3_1_7bID : MLXModels.qwen3_0_6bID)!
    }
    var label: String {
        let mode = config.mode == .rewrite ? "rewrite-\(config.layout.rawValue)-\(config.contextPercent)" : config.mode.rawValue
        return "\(backend.rawValue)/\(model.rawValue)/\(keep.rawValue)/\(mode)"
    }
    /// The Core ML reply reserve: rewrite replies are one sentence, so the session may hold more of the window.
    static let rewriteOutputLimit = 256
}

/// Appends the continuous probe's lines to `Library/Caches/continuous-probe.jsonl` as well: the shared
/// diagnostics file restarts at 1 MB, this one is only ever appended to.
enum ContinuousProbeFile {
    static var url: URL { URL.cachesDirectory.appending(path: "continuous-probe.jsonl") }
    private static let queue = DispatchQueue(label: "de.gruenwald.legato.continuous-probe")

    static func write(_ event: String, _ fields: [String: any Sendable]) {
        var line = fields.mapValues { $0 as Any }
        line["event"] = event
        line["t"] = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        queue.async {
            let file = url
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + [0x0A])
        }
    }
}

extension SessionProbe {
    /// Spike #95: the continuous cleanup agent on one backend and model. Releases the app's models, makes sure
    /// the probe's model is on disk (downloading it if missing), loads it in the foreground, keeps the app
    /// running per `LEGATO_PROBE_BG`, waits for the background (unless `foreground`), replays the stream and
    /// logs one line per chunk plus a summary. The model is released at the end; each backend is its own run.
    static func runContinuous(models: ModelServices) async {
        let options: ContinuousProbeOptions
        switch ContinuousProbeOptions.from(ProcessInfo.processInfo.environment) {
        case .success(let value): options = value
        case .failure(let invalid):
            SessionProbe.emit("session.probe.continuous.done", ["ok": false, "error": invalid.reason])
            return
        }
        running = true; warnings = 0
        mode = .continuous
        block?(true)
        defer { running = false; block?(false) }
        let keepAlive = options.keep == .foreground ? nil : BackgroundTask(mode: .continuous)
        defer { keepAlive?.end() }
        var baseFields: [String: any Sendable] = ["backend": options.backend.rawValue, "model": options.model.rawValue, "bg": options.keep.rawValue,
                                              "mode": options.config.mode.rawValue]
        if options.config.mode == .rewrite {
            baseFields["layout"] = options.config.layout.rawValue; baseFields["ctxPct"] = options.config.contextPercent
            baseFields["prompt"] = options.config.prompt.rawValue
        }
        let base = baseFields
        func emit(_ event: String, _ fields: [String: any Sendable] = [:]) { line(event, fields, base) }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let wallStart = ContinuousClock.now
        let thermalStart = thermalName
        let batteryStart = UIDevice.current.batteryLevel
        let memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { warnings += 1; line("session.probe.continuous.memoryWarning", Memory.now().sendableFields, base) } }
        defer { NotificationCenter.default.removeObserver(memoryObserver) }
        let thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { line("session.probe.continuous.thermal", ["thermal": thermalName], base) } }
        defer { NotificationCenter.default.removeObserver(thermalObserver) }
        // MLX on the phone's CPU runs with compile off (no JIT compiler on iOS); the start line says which.
        if options.backend == .mlxCPU { MLXCompile.prepare(for: .cpu) }
        emit("session.probe.continuous.start", [
            "compile": MLXCompile.label,
            "thermal": thermalStart, "batteryLevel": Double(batteryStart), "batteryState": UIDevice.current.batteryState.rawValue,
            "wps": options.config.wordsPerSecond, "repeats": options.config.repeats, "warm": options.config.warmContinuation,
            "seed": Int(options.config.seed), "streamSeconds": Int(options.config.streamSeconds()),
            "corpusWords": ProbeCorpus.wordCount, "corpusMistakes": ProbeCorpus.mistakeCount,
            "window": options.config.window, "linger": String(describing: Settings.keepAliveLinger),
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ].merging(options.config.modeFields) { $1 })

        say("releasing the app's own models")
        await AppController.shared.releaseModelsForProbe()
        try? await Task.sleep(for: .seconds(1))
        emit("session.probe.continuous.memory", Memory.now().sendableFields.merging(["phase": "afterRelease"]) { $1 })

        // Model on disk (download if missing), then load in the foreground: a background start may not load.
        let root = ModelServices.phoneModelsRoot
        let folder: URL
        let installer: any ModelInstaller
        switch options.backend {
        case .coreml:
            installer = CoreMLInstaller(spec: options.coreMLSpec); folder = options.coreMLSpec.folder(root: root)
        case .mlxCPU:
            installer = MLXInstaller(spec: options.mlxSpec); folder = options.mlxSpec.folder(root: root)
        }
        if await !installer.isInstalled(root: root) {
            say("downloading \(options.model.rawValue) for \(options.backend.rawValue)")
            let start = ContinuousClock.now
            do {
                try await installer.install(root: root) { _ in }
                emit("session.probe.continuous.download", ["ok": true, "wallMs": ms(ContinuousClock.now - start), "folderMB": folderMB(folder)])
            } catch {
                emit("session.probe.continuous.download", ["ok": false, "wallMs": ms(ContinuousClock.now - start), "error": describe(error)])
                emit("session.probe.continuous.done", ["ok": false, "error": "download failed"])
                await restore(options)
                return
            }
        }
        let modelMB = folderMB(folder)

        say("loading \(options.label)")
        let peak = PeakSampler()
        peak.start()
        defer { peak.stop() }
        let loadStart = ContinuousClock.now
        let backend: any LLMBackend
        let release: @Sendable () async -> Void
        do {
            switch options.backend {
            case .coreml:
                let coreML = options.config.mode == .rewrite
                    ? CoreMLBackend(spec: options.coreMLSpec, folder: folder, outputTokenLimit: ContinuousProbeOptions.rewriteOutputLimit)
                    : await CoreMLModelStore.shared.backend(for: options.coreMLSpec, root: root)
                try await coreML.prepare()
                backend = coreML
                release = { await coreML.releaseWarmResources(); await CoreMLModelStore.shared.release(folder: folder) }
            case .mlxCPU:
                let mlx = MLXBackend(spec: options.mlxSpec, folder: folder, device: .cpu)
                try await mlx.prewarmResources()
                backend = mlx
                release = { await mlx.releaseWarmResources() }
            }
        } catch {
            emit("session.probe.continuous.load", ["ok": false, "error": describe(error), "wallMs": ms(ContinuousClock.now - loadStart)])
            emit("session.probe.continuous.done", ["ok": false, "error": "load failed"])
            await restore(options)
            return
        }
        let counter = await MLXProbeSupport.tokenCounter(folder: folder)
        let loaded: [String: any Sendable] = [
            "ok": true, "wallMs": ms(ContinuousClock.now - loadStart), "modelMB": modelMB, "folder": folder.lastPathComponent,
            "peakFootprintMB": Int(peak.peakFootprintMB), "tokenizer": counter != nil,
        ]
        emit("session.probe.continuous.load", loaded.merging(Memory.now().sendableFields) { $1 })

        if options.keep == .audio {
            let armed = await AppController.shared.perform(.arm)
            emit("session.probe.continuous.arm", ["armed": armed])
        }
        if options.keep != .foreground {
            say("\(options.label) loaded; send the app to the background to start")
            let deadline = ContinuousClock.now + .seconds(180)
            while UIApplication.shared.applicationState != .background, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            emit("session.probe.continuous.background", ["inBackground": UIApplication.shared.applicationState == .background])
        }

        say("replaying the stream on \(options.label)")
        let replayStart = ContinuousClock.now
        let thermalReplayStart = thermalName
        let batteryReplayStart = UIDevice.current.batteryLevel
        let hooks = ContinuousAgentProbe.Hooks(
            countTokens: { reply in counter?(reply) },
            onTurn: { record in await line("session.probe.continuous.turn", record.fields, base) },
            onEvent: { name, fields in await line("session.probe.continuous.\(name)", fields, base) })
        var fields: [String: any Sendable] = ["modelMB": modelMB]
        let results = await ContinuousAgentProbe.runAll(backend: backend, config: options.config, hooks: hooks)
        let ok = !results.isEmpty
        fields.merge(ProbeReport.pooled(results)) { $1 }
        if results.contains(where: { $0.phase == "warm" }) {
            emit("session.probe.continuous.summary.warm", ProbeReport.pooled(results, phase: "warm"))
        }
        for (_, group) in ProbeReport.breakdown(results) { emit("session.probe.continuous.breakdown", group) }
        peak.stop()
        fields.merge([
            "ok": ok, "peakFootprintMB": Int(peak.peakFootprintMB), "minAvailableMB": Int(peak.minAvailableMB),
            "memoryWarnings": warnings,
            "thermalStart": thermalStart, "thermalReplayStart": thermalReplayStart, "thermalEnd": thermalName,
            "batteryStart": Double(batteryStart), "batteryReplayStart": Double(batteryReplayStart),
            "batteryEnd": Double(UIDevice.current.batteryLevel),
            "replayWallS": Double(ms(ContinuousClock.now - replayStart)) / 1_000,
            "totalWallS": Double(ms(ContinuousClock.now - wallStart)) / 1_000,
        ]) { $1 }
        emit("session.probe.continuous.summary", fields)

        // Release the probe's model fully before the app's own models come back.
        await release()
        emit("session.probe.continuous.memory", Memory.now().sendableFields.merging(["phase": "afterProbeRelease"]) { $1 })
        await restore(options)
        emit("session.probe.continuous.done", ["ok": ok])
        say("done (\(ok ? "ok" : "failed")): \(options.label)")
    }

    private static func restore(_ options: ContinuousProbeOptions) async {
        await AppController.shared.endProbeHold()
        if options.keep == .audio { await AppController.shared.endKeepAlive() }
    }

    /// One run line: `fields` plus the run's `base` (backend, model, bg) and the app state.
    static func line(_ event: String, _ fields: [String: any Sendable], _ base: [String: any Sendable]) {
        var line = fields.merging(base) { $1 }
        line["appState"] = appState
        if UIApplication.shared.applicationState == .background {
            line["backgroundTimeRemainingS"] = Int(min(UIApplication.shared.backgroundTimeRemaining, 9_999))
        }
        emit(event, line)
    }

    /// One line to both the diagnostics log and the probe's own file.
    static func emit(_ event: String, _ fields: [String: any Sendable]) {
        AudioDiagnostics.log(event, fields.mapValues { $0 as Any })
        ContinuousProbeFile.write(event, fields)
    }

    /// An error as one string (the diagnostics' own `describe` is not `Sendable`).
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return String("\(ns.domain) \(ns.code): \(ns.localizedDescription)".prefix(300))
    }

    static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func folderMB(_ folder: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var bytes = 0
        for case let file as URL in files { bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return bytes / 1_048_576
    }

    /// The peak footprint and the least available memory, sampled every 250 ms without logging.
    @MainActor final class PeakSampler {
        private var task: Task<Void, Never>?
        private(set) var peakFootprintMB = 0.0
        private(set) var minAvailableMB = Double.greatestFiniteMagnitude
        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        func sample() {
            let memory = Memory.now()
            peakFootprintMB = max(peakFootprintMB, memory.footprintMB)
            minAvailableMB = min(minAvailableMB, memory.availableMB)
        }
        func stop() { sample(); task?.cancel(); task = nil }
    }
}

extension SessionProbe.Memory {
    var sendableFields: [String: any Sendable] { ["footprintMB": Int(footprintMB), "availableMB": Int(availableMB)] }
}
#endif
