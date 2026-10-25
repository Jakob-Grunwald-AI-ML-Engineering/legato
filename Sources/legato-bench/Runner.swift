#if os(macOS)
import AVFAudio
import Foundation
import LegatoAppleSpeech
import LegatoCore
import LegatoEngines
import LegatoFluidAudio
import LegatoModels

/// Command line of the latency bench. Logs go to stderr, the Markdown table to stdout.
enum BenchCLI {
    struct Options {
        var engines = ["apple", "nemotron-multilingual", "nemotron-latin", "eou"]
        var tiers: Set<Int>?
        var silences = [500, 800, 1200]
        var clips = ["de", "en", "mixed-long"]
        var modelsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/LegatoTests/Models", directoryHint: .isDirectory)
        var out: URL?
        var runs = 1
    }

    static func main(arguments: [String]) async {
        let options: Options
        do { options = try parse(arguments) } catch {
            log("error: \(error)")
            log(usage)
            exit(2)
        }
        do {
            try await BenchRunner(options: options).run()
        } catch {
            log("error: \(error)")
            exit(1)
        }
    }

    static let usage = """
        usage: legato-bench [--engines apple,nemotron-multilingual,nemotron-latin,eou] [--tiers 560,1120,2240,160,320]
                            [--silence 500,800,1200] [--clips de,en,mixed-long] [--runs N]
                            [--models-root PATH] [--out results.json]
        """

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw UsageError(description: "\(flag) needs a value") }
            return arguments[index]
        }
        func ints(_ flag: String) throws -> [Int] {
            try value(flag).split(separator: ",").map {
                guard let n = Int($0) else { throw UsageError(description: "\(flag): '\($0)' is not a number") }
                return n
            }
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--engines": options.engines = try value(flag).split(separator: ",").map(String.init)
            case "--tiers": options.tiers = Set(try ints(flag))
            case "--silence": options.silences = try ints(flag)
            case "--clips": options.clips = try value(flag).split(separator: ",").map(String.init)
            case "--models-root": options.modelsRoot = URL(fileURLWithPath: (try value(flag) as NSString).expandingTildeInPath)
            case "--out": options.out = URL(fileURLWithPath: (try value(flag) as NSString).expandingTildeInPath)
            case "--runs": options.runs = max(try ints(flag).first ?? 1, 1)
            default: throw UsageError(description: "unknown flag \(flag)")
            }
            index += 1
        }
        return options
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A clip decoded to 16 kHz mono Float32.
struct Clip {
    var name: String
    var languages: Set<String>
    var samples: [Float]

    static let known: [String: Set<String>] = ["de": ["de"], "en": ["en"], "mixed-long": ["de", "en"]]

    static func load(_ name: String) throws -> Clip {
        guard let languages = known[name] else { throw BenchCLI.UsageError(description: "unknown clip \(name)") }
        guard let url = Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Clips") else {
            throw BenchCLI.UsageError(description: "clip \(name).m4a is missing from the bundle")
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
            throw BenchCLI.UsageError(description: "\(name).m4a must be 16 kHz mono")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchCLI.UsageError(description: "cannot allocate for \(name)")
        }
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return Clip(name: name, languages: languages, samples: samples)
    }
}

/// One engine configuration to measure.
struct BenchConfig {
    var engine: String
    var modelID: String?
    var tierMs: Int?
    var silenceMs: Int?
}

struct BenchRunner {
    static let rmsThreshold: Float = 0.004
    static let sampleRate = 16_000.0
    static let chunkSamples = 320  // 20 ms

    let options: BenchCLI.Options

    func run() async throws {
        let clips = try options.clips.map(Clip.load)
        let models = FluidAudioCatalog.makeManager(
            root: options.modelsRoot,
            selection: SelectionStore(defaults: UserDefaults(suiteName: "legato.bench.selection") ?? .standard))
        let configs = makeConfigs()
        log("bench: \(configs.count) configs x \(clips.count) clips x \(options.runs) run(s); models at \(options.modelsRoot.path)")

        var results: [Bench.ConfigResult] = []
        for (number, config) in configs.enumerated() {
            log("[\(number + 1)/\(configs.count)] \(config.modelID ?? config.engine) silence=\(config.silenceMs.map(String.init) ?? "-")")
            if let id = config.modelID { try await ensureInstalled(id, models: models) }
            var result = Bench.ConfigResult(
                engine: config.engine, model: config.modelID, tierMs: config.tierMs, silenceMs: config.silenceMs, runs: [])
            let compatible = clips.filter { config.engine != "eou" || $0.languages == ["en"] }
            if let warm = compatible.first { await warmUp(config, clip: warm, models: models) }
            for clip in compatible {
                for _ in 0..<options.runs {
                    let run = await runOnce(config, clip: clip, models: models)
                    log("    \(clip.name): first=\(run.firstWordMs.map { String(Int($0)) } ?? "-") ms, finals=\(run.finalizationMs.count), punct=\(run.punctuation)\(run.error.map { ", ERROR \($0)" } ?? "")")
                    result.runs.append(run)
                }
            }
            result.summary = Bench.summarize(result)
            results.append(result)
            try write(results)
        }
        print(Bench.markdown(results))
    }

    // MARK: configs

    func makeConfigs() -> [BenchConfig] {
        var configs: [BenchConfig] = []
        func tierAllowed(_ ms: Int) -> Bool { options.tiers?.contains(ms) ?? true }
        for engine in options.engines {
            switch engine {
            case "apple":
                // Apple Speech has no silence setting; it finalizes on its own.
                configs.append(BenchConfig(engine: "apple-speech"))
            case "nemotron-multilingual", "nemotron-latin":
                let variant: NemotronVariant = engine == "nemotron-latin" ? .latin : .multilingual
                for tier in NemotronInstaller.supportedChunks where tierAllowed(tier) {
                    for silence in options.silences {
                        configs.append(BenchConfig(
                            engine: engine, modelID: FluidAudioModels.nemotronID(variant, chunkMs: tier),
                            tierMs: tier, silenceMs: silence))
                    }
                }
            case "eou":
                for chunk in EouChunk.allCases where tierAllowed(chunk.rawValue) {
                    for silence in options.silences {
                        configs.append(BenchConfig(
                            engine: "parakeet-eou", modelID: FluidAudioModels.eouID(chunk), tierMs: chunk.rawValue,
                            silenceMs: silence))
                    }
                }
            default:
                log("warning: unknown engine '\(engine)' skipped")
            }
        }
        return configs
    }

    func makeEngine(_ config: BenchConfig, models: ModelManager) -> any DictationEngine {
        if let id = config.modelID,
            let engine = FluidAudioCatalog.liveEngine(
                id: id, preferredLocales: [], silenceMs: config.silenceMs ?? FluidAudioCatalog.defaultSilenceMs, models: models)
        {
            return engine
        }
        return AppleSpeechEngine()
    }

    /// Installing a missing tier is an explicit action of running the bench.
    func ensureInstalled(_ id: String, models: ModelManager) async throws {
        if case .installed = await models.state(of: id) { return }
        log("  installing \(id) ...")
        var lastReported = -1
        var final: ModelState = .notInstalled
        for await state in await models.install(id) {
            final = state
            if case .downloading(let fraction) = state, Int(fraction * 10) > lastReported {
                lastReported = Int(fraction * 10)
                log("    download \(lastReported * 10)%")
            } else if case .warming = state {
                log("    warming (first Neural Engine compile) ...")
            }
        }
        guard case .installed = final else { throw BenchCLI.UsageError(description: "install of \(id) ended as \(final)") }
    }

    // MARK: playing a clip

    func locale(for clip: Clip) -> Locale {
        clip.name == "de" ? Locale(identifier: "de-DE") : Locale(identifier: "en-US")
    }

    /// Prepares, installing Apple's assets once if they are missing.
    func prepare(_ engine: any DictationEngine, locale: Locale) async throws {
        do {
            _ = try await engine.prepare(locale: locale)
        } catch DictationError.assetsNotInstalled where engine.id == "apple-speech" {
            log("  installing Apple Speech assets for \(locale.identifier) ...")
            for await _ in engine.installAssets(locale: locale) {}
            _ = try await engine.prepare(locale: locale)
        }
    }

    /// An untimed pass through the whole pipeline, so first-inference costs stay out of the measurements.
    func warmUp(_ config: BenchConfig, clip: Clip, models: ModelManager) async {
        let engine = makeEngine(config, models: models)
        do {
            try await prepare(engine, locale: locale(for: clip))
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
            let consumer = Task { for try await _ in engine.transcribe(stream) {} }
            let spec = AudioFormatSpec(sampleRate: Self.sampleRate, channelCount: 1)
            let head = Array(clip.samples.prefix(Int(Self.sampleRate) * 3))
            for start in stride(from: 0, to: head.count, by: Self.chunkSamples) {
                continuation.yield(AudioChunk(samples: Array(head[start..<min(start + Self.chunkSamples, head.count)]), format: spec))
            }
            continuation.finish()
            try await engine.finish()
            try await consumer.value
        } catch {
            log("  warm-up failed: \(error)")
        }
    }

    func runOnce(_ config: BenchConfig, clip: Clip, models: ModelManager) async -> Bench.RunResult {
        let silenceMs = config.silenceMs ?? FluidAudioCatalog.defaultSilenceMs
        // Trailing silence lets the silence endpointer commit the last sentence, as it would live.
        let samples = clip.samples + [Float](repeating: 0, count: Int(Self.sampleRate * (Double(silenceMs) / 1000 + 0.5)))
        let onset = Bench.speechOnset(samples: samples, sampleRate: Self.sampleRate, rmsThreshold: Self.rmsThreshold)
        let ends = Bench.speechSegments(
            samples: samples, sampleRate: Self.sampleRate, silenceMs: silenceMs, rmsThreshold: Self.rmsThreshold
        ).map(\.upperBound)

        let engine = makeEngine(config, models: models)
        var events: [Bench.Event] = []
        var feedTimes: [Double] = []
        var failure: String?
        do {
            try await prepare(engine, locale: locale(for: clip))
            (events, feedTimes) = try await play(samples, into: engine)
        } catch {
            failure = String(describing: error)
        }

        let clock = Bench.FeedClock(chunkSeconds: Double(Self.chunkSamples) / Self.sampleRate, feedTimes: feedTimes)
        let transcript = events.filter(\.isFinal).map(\.text).joined(separator: " ")
        return Bench.RunResult(
            clip: clip.name,
            firstWordMs: Bench.firstWordLatency(onset: onset, events: events, clock: clock).map { $0 * 1000 },
            emissionLagsMs: Bench.emissionLags(events: events, clock: clock).map { $0 * 1000 },
            finalizationMs: Bench.finalizationLatencies(sentenceEnds: ends, events: events, clock: clock).map { $0.map { $0 * 1000 } },
            sentences: ends.count,
            transcript: transcript,
            punctuation: Bench.punctuationCount(transcript),
            error: failure)
    }

    /// Feeds `samples` in 20 ms chunks on a real-time clock and records every event with its arrival time.
    func play(_ samples: [Float], into engine: any DictationEngine) async throws -> ([Bench.Event], [Double]) {
        let clock = ContinuousClock()
        let spec = AudioFormatSpec(sampleRate: Self.sampleRate, channelCount: 1)
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let start = clock.now
        @Sendable func elapsed() -> Double {
            let d = clock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }

        let feeder = Task { () -> [Double] in
            var times: [Double] = []
            let step = Double(Self.chunkSamples) / Self.sampleRate
            for (index, from) in stride(from: 0, to: samples.count, by: Self.chunkSamples).enumerated() {
                if Task.isCancelled { break }
                try? await clock.sleep(until: start + .seconds(Double(index) * step))
                times.append(elapsed())
                continuation.yield(AudioChunk(samples: Array(samples[from..<min(from + Self.chunkSamples, samples.count)]), format: spec))
            }
            continuation.finish()
            return times
        }
        let consumer = Task { () -> [Bench.Event] in
            var events: [Bench.Event] = []
            for try await event in engine.transcribe(stream) {
                events.append(Bench.Event(wall: elapsed(), text: event.text, isFinal: event.isFinal, rangeEnd: event.range?.upperBound))
            }
            return events
        }
        let times = await feeder.value
        do {
            try await engine.finish()
            let events = try await consumer.value
            return (events, times)
        } catch {
            consumer.cancel()
            throw error
        }
    }

    // MARK: output

    func write(_ results: [Bench.ConfigResult]) throws {
        guard let out = options.out else { return }
        struct Report: Codable {
            var generated: Date
            var os: String
            var arguments: [String]
            var configs: [Bench.ConfigResult]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let report = Report(
            generated: Date(), os: ProcessInfo.processInfo.operatingSystemVersionString,
            arguments: Array(CommandLine.arguments.dropFirst()), configs: results)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: out)
    }
}
#endif
