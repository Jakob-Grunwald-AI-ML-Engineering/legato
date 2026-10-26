import AVFAudio
import Foundation
import LegatoCore
import LegatoModels
import Testing
@testable import LegatoFluidAudio

private let realEngineEnabled = ProcessInfo.processInfo.environment["LEGATO_REAL_ENGINE"] == "1"

/// A persistent root so reruns reuse the downloads. Override with `LEGATO_TEST_MODEL_ROOT`.
private let modelRoot: URL = {
    if let path = ProcessInfo.processInfo.environment["LEGATO_TEST_MODEL_ROOT"] { return URL(fileURLWithPath: path) }
    return URL.cachesDirectory.appendingPathComponent("LegatoTests/Models")
}()

private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

private func makeManager() -> ModelManager {
    let defaults = UserDefaults(suiteName: "legato-real-engine-tests")!
    return ModelManager(
        root: modelRoot, catalog: FluidAudioModels.descriptors, installers: FluidAudioModels.installers,
        selection: SelectionStore(defaults: defaults))
}

/// Installs and warms the model if it is missing (a first run downloads and compiles for minutes).
private func ensureInstalled(_ manager: ModelManager, _ id: String) async throws {
    let clock = ContinuousClock()
    let started = clock.now
    var last = ModelState.notInstalled
    for await state in await manager.install(id) { last = state }
    guard case .installed(let bytes) = last else {
        Issue.record("\(id) did not install: \(last)")
        throw CancellationError()
    }
    print("MODEL \(id): installed, \(bytes / 1_000_000) MB, ensureInstalled took \(clock.now - started)")
}

/// Reads a fixture and resamples it to 16 kHz mono Float32.
private func fixtureSamples(_ name: String, extension ext: String = "aiff") throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    let file = try AVAudioFile(forReading: url)
    let inBuf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: inBuf)
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: spec.sampleRate, channels: 1, interleaved: true))
    let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
    let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * spec.sampleRate / file.processingFormat.sampleRate) + 1024
    let out = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
    nonisolated(unsafe) var consumed = false  // single-threaded converter callback
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return inBuf
    }
    #expect(error == nil)
    return Array(UnsafeBufferPointer(start: try #require(out.floatChannelData?[0]), count: Int(out.frameLength)))
}

/// Runs one dictation session over `samples` and returns the committed text, the events and how long `prepare` took.
private func dictate(
    _ engine: some DictationEngine, samples: [Float], locale: Locale? = nil
) async throws -> (text: String, events: [TranscriptEvent], prepare: Duration) {
    let clock = ContinuousClock()
    let started = clock.now
    let format = try await engine.prepare(locale: locale)
    let prepare = clock.now - started
    #expect(format == spec)

    let chunk = Int(format.sampleRate / 10)
    let (input, feed) = AsyncStream.makeStream(of: AudioChunk.self)
    let stream = engine.transcribe(input)
    let feeder = Task {
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            feed.yield(AudioChunk(samples: Array(samples[i..<end]), format: format))
            i = end
        }
        feed.finish()
    }
    let collector = Task {
        var assembler = TranscriptAssembler()
        var events: [TranscriptEvent] = []
        for try await event in stream {
            events.append(event)
            _ = assembler.apply(event)
        }
        return (assembler.committedText, events)
    }
    await feeder.value
    try await engine.finish()
    let (text, events) = try await collector.value
    return (text, events, prepare)
}

@Suite("Real FluidAudio engines", .serialized)
struct RealEngineTests {
    @Test(.enabled(if: realEngineEnabled, "set LEGATO_REAL_ENGINE=1 to run against the on-device models"))
    func nemotronMultilingualTranscribesEnglishAndReusesLoadedModels() async throws {
        let manager = makeManager()
        let id = FluidAudioModels.nemotronID(.multilingual, chunkMs: 1120)
        try await ensureInstalled(manager, id)
        let samples = try fixtureSamples("hello-en")

        let engine = NemotronEngine(variant: .multilingual, chunkMs: 1120, models: manager)
        #expect(engine.id == id)
        let first = try await dictate(engine, samples: samples)
        print("NEMOTRON-EN first prepare \(first.prepare): \"\(first.text)\" events=\(first.events.count) ranges=\(first.events.compactMap(\.range))")
        let lowered = first.text.lowercased()
        #expect(lowered.contains("hello"))
        #expect(lowered.contains("dictation"))
        #expect(first.events.contains { !$0.isFinal && !$0.text.isEmpty }, "partials arrive before the final")

        // The same engine again, then a fresh engine over the same folder: both reuse the loaded models.
        let second = try await dictate(engine, samples: samples)
        print("NEMOTRON-EN second prepare (same engine) \(second.prepare): \"\(second.text)\"")
        #expect(second.prepare < .seconds(2))
        #expect(second.text.lowercased().contains("hello"))

        let fresh = NemotronEngine(variant: .multilingual, chunkMs: 1120, models: manager)
        let third = try await dictate(fresh, samples: samples)
        print("NEMOTRON-EN third prepare (new engine) \(third.prepare): \"\(third.text)\"")
        #expect(third.prepare < .seconds(2))
    }

    @Test(.enabled(if: realEngineEnabled, "set LEGATO_REAL_ENGINE=1 to run against the on-device models"))
    func nemotronMultilingualTranscribesGerman() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.nemotronID(.multilingual, chunkMs: 1120))
        let samples = try fixtureSamples("hallo-de")

        let auto = NemotronEngine(variant: .multilingual, chunkMs: 1120, models: manager)
        let result = try await dictate(auto, samples: samples)
        print("NEMOTRON-DE auto prepare \(result.prepare): \"\(result.text)\" ranges=\(result.events.compactMap(\.range))")
        let lowered = result.text.lowercased()
        #expect(lowered.contains("hallo"))
        #expect(lowered.contains("diktat"))

        let pinned = NemotronEngine(
            variant: .multilingual, chunkMs: 1120, preferredLocales: [Locale(identifier: "de_DE")], models: manager)
        let hinted = try await dictate(pinned, samples: samples)
        print("NEMOTRON-DE de hint prepare \(hinted.prepare): \"\(hinted.text)\"")
        #expect(hinted.text.lowercased().contains("diktat"))
    }

    /// 19 alternating German and English sentences (`Sources/legato-bench/Clips/README.md`) on `auto`: every
    /// sentence is committed. A session locale would pin one language and drop the other's sentences.
    @Test(.enabled(if: realEngineEnabled, "set LEGATO_REAL_ENGINE=1 to run against the on-device models"))
    func nemotronOnAutoKeepsEverySentenceOfTheMixedClip() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.nemotronID(.multilingual, chunkMs: 1120))
        // Trailing silence lets the endpointer commit the last sentence, as it would live.
        let samples = try fixtureSamples("mixed-long", extension: "m4a") + [Float](repeating: 0, count: 16_000 * 2)

        let engine = NemotronEngine(variant: .multilingual, chunkMs: 1120, models: manager)
        let result = try await dictate(engine, samples: samples)
        let finals = result.events.filter(\.isFinal)
        print("NEMOTRON-MIXED \(finals.count) finals: \"\(result.text)\"")
        #expect(finals.count == 19)
        let lowered = result.text.lowercased()
        for phrase in ["guten morgen", "backend", "ich schlage vor", "first milestone", "feierabend"] {
            #expect(lowered.contains(phrase), "missing \"\(phrase)\"")
        }
    }

    @Test(.enabled(if: realEngineEnabled, "set LEGATO_REAL_ENGINE=1 to run against the on-device models"))
    func parakeetEouTranscribesEnglish() async throws {
        let manager = makeManager()
        let id = FluidAudioModels.eouID(.ms160)
        try await ensureInstalled(manager, id)
        let engine = ParakeetEouEngine(chunk: .ms160, models: manager)
        #expect(engine.id == id)
        let result = try await dictate(engine, samples: try fixtureSamples("hello-en"))
        print("EOU-EN prepare \(result.prepare): \"\(result.text)\" events=\(result.events.count) ranges=\(result.events.compactMap(\.range))")
        let lowered = result.text.lowercased()
        #expect(lowered.contains("hello"))
        #expect(lowered.contains("dictation"))
    }

    @Test(.enabled(if: realEngineEnabled, "set LEGATO_REAL_ENGINE=1 to run against the on-device models"), arguments: [ParakeetBatchModel.v3, .ultra])
    func parakeetBatchTranscribesEnglish(model: ParakeetBatchModel) async throws {
        let manager = makeManager()
        let transcriber = ParakeetTranscriber(model: model, models: manager)
        try await ensureInstalled(manager, model == .v3 ? FluidAudioModels.parakeetV3ID : FluidAudioModels.parakeetUltraID)
        let samples = try fixtureSamples("hello-en")
        let clock = ContinuousClock()
        let started = clock.now
        let events = try await transcriber.transcribe(samples: samples, stream: .mic)
        let shown = events.map { "\"\($0.text)\" \($0.range.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "nil")" }
        print("PARAKEET \(transcriber.id) took \(clock.now - started): \(shown)")

        let text = events.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("hello"))
        #expect(text.contains("dictation"))
        #expect(events.allSatisfy { $0.isFinal && $0.range != nil })
        let ranges = events.compactMap(\.range)
        let duration = Double(samples.count) / 16_000
        #expect(ranges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= duration + 0.001 && $0.lowerBound <= $0.upperBound })
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound <= b.lowerBound) }
    }
}
