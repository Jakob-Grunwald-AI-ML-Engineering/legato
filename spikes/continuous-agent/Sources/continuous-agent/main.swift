import Foundation
import LegatoCore
import LegatoCoreML
import LegatoMLX
import LegatoModels

// Spike #95 Mac runner. One process runs the selected matrix (backend × model) one combination at a time,
// releasing each model before the next. JSON lines go to stdout and --out; a summary table ends the run.

enum Backend: String, CaseIterable { case coreml, mlxGPU = "mlx-gpu", mlxCPU = "mlx-cpu" }
enum Model: String, CaseIterable { case qwen3_1_7b = "qwen3-1.7b", qwen3_0_6b = "qwen3-0.6b" }

struct Arguments {
    var backends = Backend.allCases
    var models = Model.allCases
    var root = URL.applicationSupportDirectory.appending(path: "Legato/Models", directoryHint: .isDirectory)
    var out = URL(fileURLWithPath: "continuous-agent-\(Int(Date().timeIntervalSince1970)).jsonl")
    var config = ProbeConfig(environment: ProcessInfo.processInfo.environment)
    /// Only the first n corpus sentences (a quick check); nil: the whole corpus.
    var sentences: Int?
    var corpus: [ProbeSentence] { sentences.map { Array(ProbeCorpus.sentences.prefix(max(1, $0))) } ?? ProbeCorpus.sentences }

    static let usage = """
        usage: continuous-agent [--backend coreml|mlx-gpu|mlx-cpu|all] [--model qwen3-1.7b|qwen3-0.6b|all]
                                [--wps 2.5] [--repeats 3] [--warm 1|0] [--seed 95] [--window 1000] [--root <models>] [--out <file.jsonl>]
                                [--cpu-compile on|off] [--sentences n]
                                [--mode edits|rewrite] [--layout onepass|turns] [--ctx-pct 25] [--pause-ms 700] [--max-sentence-words 30]
        """

    static func parse(_ argv: [String]) throws -> Arguments {
        var args = Arguments()
        var iterator = argv.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw Failure("\(flag) needs a value\n\(usage)") }
            return next
        }
        while let flag = iterator.next() {
            switch flag {
            case "--backend":
                let v = try value(flag)
                args.backends = v == "all" ? Backend.allCases : try v.split(separator: ",").map {
                    guard let b = Backend(rawValue: String($0)) else { throw Failure("unknown backend \($0)") }; return b
                }
            case "--model":
                let v = try value(flag)
                args.models = v == "all" ? Model.allCases : try v.split(separator: ",").map {
                    guard let m = Model(rawValue: String($0)) else { throw Failure("unknown model \($0)") }; return m
                }
            case "--wps": args.config.wordsPerSecond = Double(try value(flag)) ?? args.config.wordsPerSecond
            case "--repeats": args.config.repeats = max(1, Int(try value(flag)) ?? args.config.repeats)
            case "--warm": args.config.warmContinuation = try value(flag) != "0"
            case "--seed": args.config.seed = UInt64(try value(flag)) ?? args.config.seed
            case "--window": args.config.window = Int(try value(flag)) ?? args.config.window
            case "--cpu-compile":
                let v = try value(flag)
                guard v == "on" || v == "off" else { throw Failure("--cpu-compile is on or off") }
                MLXCompile.allowedOnCPU = v == "on"
            case "--sentences": args.sentences = Int(try value(flag))
            case "--mode":
                let v = try value(flag)
                guard let mode = ProbeMode(rawValue: v) else { throw Failure("--mode is edits or rewrite") }
                args.config.mode = mode
            case "--layout":
                let v = try value(flag)
                guard let layout = ProbeLayout(rawValue: v) else { throw Failure("--layout is onepass or turns") }
                args.config.layout = layout
            case "--ctx-pct": args.config.contextPercent = min(100, max(1, Int(try value(flag)) ?? args.config.contextPercent))
            case "--pause-ms": args.config.endpoint.pauseSeconds = (Double(try value(flag)) ?? 700) / 1_000
            case "--max-sentence-words": args.config.endpoint.maxWords = max(1, Int(try value(flag)) ?? args.config.endpoint.maxWords)
            case "--root": args.root = URL(fileURLWithPath: try value(flag), isDirectory: true)
            case "--out": args.out = URL(fileURLWithPath: try value(flag))
            case "-h", "--help": print(usage); exit(0)
            default: throw Failure("unknown argument \(flag)\n\(usage)")
            }
        }
        return args
    }
}

struct Failure: Error, CustomStringConvertible { var description: String; init(_ d: String) { description = d } }

/// JSON lines to stdout and the output file.
final class Sink: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func line(_ event: String, _ fields: [String: any Sendable]) {
        var line = fields.mapValues { $0 as Any }
        line["event"] = event
        line["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        handle.write(data + [0x0A])
        FileHandle.standardOutput.write(data + [0x0A])
    }
}

func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}

func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

func folderMB(_ folder: URL) -> Int {
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var bytes = 0
    for case let file as URL in files { bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    return bytes / 1_048_576
}

func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000) }

/// Peak footprint, sampled every 250 ms.
actor Peak {
    private(set) var mb = 0
    private var task: Task<Void, Never>?
    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    func sample() { mb = max(mb, footprintMB()) }
    func stop() -> Int { sample(); task?.cancel(); task = nil; return mb }
}

struct ComboReport { var rows: [[String: any Sendable]] = []; var breakdown: [[String: any Sendable]] = [] }

func runOne(_ backend: Backend, _ model: Model, _ args: Arguments, _ sink: Sink) async -> ComboReport {
    var baseFields: [String: any Sendable] = ["backend": backend.rawValue, "model": model.rawValue, "host": "mac", "mode": args.config.mode.rawValue]
    if args.config.mode == .rewrite { baseFields["layout"] = args.config.layout.rawValue; baseFields["ctxPct"] = args.config.contextPercent }
    let base = baseFields
    func emit(_ event: String, _ fields: [String: any Sendable] = [:]) { sink.line(event, fields.merging(base) { $1 }) }
    let wallStart = ContinuousClock.now
    let thermalStart = thermal()
    let coreMLSpec = CoreMLModels.spec(id: model == .qwen3_1_7b ? CoreMLModels.qwen3_1_7bID : CoreMLModels.qwen3_0_6bID)!
    let mlxSpec = MLXModels.spec(id: model == .qwen3_1_7b ? MLXModels.qwen3_1_7bID : MLXModels.qwen3_0_6bID)!
    let installer: any ModelInstaller = backend == .coreml ? CoreMLInstaller(spec: coreMLSpec) : MLXInstaller(spec: mlxSpec)
    let folder = backend == .coreml ? coreMLSpec.folder(root: args.root) : mlxSpec.folder(root: args.root)
    var config = args.config
    // Rewrite mode sizes its context share from the model's real window.
    config.contextWindow = backend == .coreml ? coreMLSpec.runtimeConfiguration.contextLength : MLXBackend.contextWindow
    if backend == .mlxCPU { MLXCompile.prepare(for: .cpu) }
    emit("start", ["compile": MLXCompile.label, "thermal": thermal(), "footprintMB": footprintMB(), "folder": folder.path, "wps": args.config.wordsPerSecond,
                   "repeats": args.config.repeats, "warm": args.config.warmContinuation, "streamSeconds": Int(args.config.streamSeconds(args.corpus)),
                   "corpusWords": ProbeCorpus.wordCount, "corpusMistakes": ProbeCorpus.mistakeCount, "corpusSentences": args.corpus.count, "seed": Int(args.config.seed), "window": args.config.window]
        .merging(config.modeFields) { $1 })

    if await !installer.isInstalled(root: args.root) {
        let start = ContinuousClock.now
        do {
            try await installer.install(root: args.root) { _ in }
            emit("download", ["ok": true, "wallMs": ms(ContinuousClock.now - start), "folderMB": folderMB(folder)])
        } catch {
            emit("download", ["ok": false, "error": "\(error)"])
            return ComboReport(rows: [base.merging(["row": "failed", "error": "download failed"]) { $1 }])
        }
    }
    let modelMB = folderMB(folder)

    let peak = Peak()
    await peak.start()
    let loadStart = ContinuousClock.now
    let llm: any LLMBackend
    do {
        switch backend {
        case .coreml:
            // Rewrite replies are one sentence: a small reply reserve leaves the session more of the window.
            let coreML = config.mode == .rewrite
                ? CoreMLBackend(spec: coreMLSpec, folder: folder, outputTokenLimit: 256)
                : await CoreMLModelStore.shared.backend(for: coreMLSpec, root: args.root)
            try await coreML.prepare()
            llm = coreML
        case .mlxGPU, .mlxCPU:
            let mlx = MLXBackend(spec: mlxSpec, folder: folder, device: backend == .mlxGPU ? .gpu : .cpu, canUseGPU: { true })
            try await mlx.prewarmResources()
            llm = mlx
        }
    } catch {
        emit("load", ["ok": false, "error": "\(error)"])
        _ = await peak.stop()
        return ComboReport(rows: [base.merging(["row": "failed", "error": "load failed"]) { $1 }])
    }
    let counter = await MLXProbeSupport.tokenCounter(folder: folder)
    emit("load", ["ok": true, "wallMs": ms(ContinuousClock.now - loadStart), "modelMB": modelMB, "footprintMB": footprintMB(),
                  "tokenizer": counter != nil])

    let hooks = ContinuousAgentProbe.Hooks(
        countTokens: { counter?($0) },
        onTurn: { record in sink.line("turn", record.fields.merging(base) { $1 }) },
        onEvent: { name, fields in sink.line(name, fields.merging(base) { $1 }) })
    let replayStart = ContinuousClock.now
    let results = await ContinuousAgentProbe.runAll(backend: llm, config: config, hooks: hooks, corpus: args.corpus)
    let peakMB = await peak.stop()
    var report = ComboReport()
    for result in results { report.rows.append(base.merging(ProbeReport.run(result)) { $1 }.merging(["row": "\(result.phase) \(result.rep)"]) { $1 }) }
    var summary = base.merging(ProbeReport.pooled(results)) { $1 }
    summary.merge([
        "row": "fresh pooled", "modelMB": modelMB, "peakFootprintMB": peakMB, "thermalStart": thermalStart, "thermalEnd": thermal(),
        "wallS": Double(ms(ContinuousClock.now - replayStart)) / 1_000, "totalWallS": Double(ms(ContinuousClock.now - wallStart)) / 1_000,
    ]) { $1 }
    emit("summary", summary)
    report.rows.append(summary)
    for (_, group) in ProbeReport.breakdown(results) {
        emit("breakdown", group)
        report.breakdown.append(base.merging(group) { $1 })
    }
    await (llm as? any ModelResourceLifecycle)?.releaseWarmResources()
    if backend == .coreml { await CoreMLModelStore.shared.release(folder: folder) }
    emit("released", ["footprintMB": footprintMB()])
    return report
}

func table(_ rows: [[String: any Sendable]], _ columns: [String]) -> String {
    let cells = rows.map { row in columns.map { row[$0].map { "\($0)" } ?? "-" } }
    let widths = columns.indices.map { i in max(columns[i].count, cells.map { $0[i].count }.max() ?? 0) }
    func render(_ values: [String]) -> String {
        zip(values, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  ")
    }
    return ([render(columns)] + cells.map(render)).joined(separator: "\n")
}

let runColumns = ["backend", "model", "mode", "layout", "ctxPct", "row", "localLatencyMsMedian", "localLatencyMsMean", "localLatencyMsP95", "localLatencyMsSd",
                  "localFixed", "localFixedWithin2", "sentenceLatencyMsMedian", "sentenceLatencyMsP95", "sentenceFixed",
                  "wrongEdits", "turnMsMedian", "turnMsMean", "turnMsP95", "turnMsSd", "ttftMsMedian", "decodeTokPerSMedian",
                  "keepUpPct", "maxLagMs", "parseOk", "trims", "rejects", "endpointDelayMsMedian", "ctxTokensMax", "localLatencyRunMedianSd", "peakFootprintMB", "wallS"]
let breakdownColumns = ["backend", "model", "group", "localFixed", "localLatencyMsMedian", "localLatencyMsP95",
                        "sentenceFixed", "sentenceLatencyMsMedian", "wrongEdits"]

/// What the model store already holds for the selected matrix (a missing one downloads once, into `root`).
func listCache(_ args: Arguments, _ sink: Sink) async {
    for model in args.models {
        for backend in Set(args.backends.map { $0 == .coreml ? "coreml" : "mlx" }).sorted() {
            let coreMLSpec = CoreMLModels.spec(id: model == .qwen3_1_7b ? CoreMLModels.qwen3_1_7bID : CoreMLModels.qwen3_0_6bID)!
            let mlxSpec = MLXModels.spec(id: model == .qwen3_1_7b ? MLXModels.qwen3_1_7bID : MLXModels.qwen3_0_6bID)!
            let installer: any ModelInstaller = backend == "coreml" ? CoreMLInstaller(spec: coreMLSpec) : MLXInstaller(spec: mlxSpec)
            let folder = backend == "coreml" ? coreMLSpec.folder(root: args.root) : mlxSpec.folder(root: args.root)
            sink.line("cache", ["model": model.rawValue, "format": backend, "repo": backend == "coreml" ? coreMLSpec.repo : mlxSpec.repo,
                                "revision": backend == "coreml" ? coreMLSpec.revision : mlxSpec.revision, "folder": folder.path,
                                "installed": await installer.isInstalled(root: args.root), "folderMB": folderMB(folder)])
        }
    }
}

do {
    let args = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    let sink = try Sink(args.out)
    await listCache(args, sink)
    var rows: [[String: any Sendable]] = [], breakdown: [[String: any Sendable]] = []
    for model in args.models {
        for backend in args.backends {
            let report = await runOne(backend, model, args, sink)
            rows += report.rows; breakdown += report.breakdown
        }
    }
    let rendered = table(rows, runColumns) + "\n\n" + table(breakdown, breakdownColumns)
    print("\n" + rendered)
    try? (rendered + "\n").write(to: args.out.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("results: \(args.out.path)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("continuous-agent: \(error)\n".utf8))
    exit(2)
}
