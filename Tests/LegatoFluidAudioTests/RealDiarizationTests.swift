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
    let defaults = UserDefaults(suiteName: "legato-real-diarization-tests")!
    return ModelManager(
        root: modelRoot, catalog: FluidAudioModels.descriptors, installers: FluidAudioModels.installers,
        selection: SelectionStore(defaults: defaults))
}

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

/// Reads an audio file and resamples it to 16 kHz mono Float32.
private func samples(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inBuf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: inBuf)
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true))
    let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
    let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
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

/// `mixed-long.m4a`: 19 sentences alternating Anna (German, odd) and Samantha (English, even).
private func mixedLong() throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: "mixed-long", withExtension: "m4a", subdirectory: "Fixtures"))
    return try samples(of: url)
}

/// The bench clips: `en.m4a` is Samantha alone, `de.m4a` is Anna alone.
private func benchClip(_ name: String) throws -> [Float] {
    let clips = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/legato-bench/Clips")
    return try samples(of: clips.appendingPathComponent("\(name).m4a"))
}

private func frames(_ samples: [Float], size: Int = 1_600) -> [[Float]] {
    stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
}

private func speechSeconds(_ turns: [SpeakerTurn]) -> [String: Double] {
    Dictionary(grouping: turns, by: \.speaker).mapValues { $0.reduce(0) { $0 + $1.duration } }
}

private let gate = "set LEGATO_REAL_ENGINE=1 to run against the on-device models"

@Suite("Real diarization and enhancement", .serialized)
struct RealDiarizationTests {
    @Test(.enabled(if: realEngineEnabled, Comment(rawValue: gate)))
    func offlineDiarizerFindsAtLeastTwoSpeakersInTheMixedClip() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.diarizerOfflineID)
        let audio = try mixedLong()
        let clock = ContinuousClock()
        let started = clock.now
        let turns = try await OfflineSpeakerDiarizer(models: manager).diarize(samples: audio)
        let seconds = speechSeconds(turns)
        print("OFFLINE-DIARIZE \(clock.now - started) for \(audio.count / 16_000) s: \(turns.count) turns, speech by speaker \(seconds)")
        #expect(seconds.count >= 2)
    }

    @Test(.enabled(if: realEngineEnabled, Comment(rawValue: gate)))
    func liveDiarizerFindsAtLeastTwoSpeakersInTheMixedClip() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.sortformerID)
        let audio = try mixedLong()
        let diarizer = SortformerSpeakerDiarizer(models: manager)
        let clock = ContinuousClock()
        let started = clock.now
        for frame in frames(audio) { try await diarizer.feed(AudioChunk(samples: frame, format: spec)) }
        let turns = try await diarizer.finish()
        let seconds = speechSeconds(turns)
        print("LIVE-DIARIZE \(clock.now - started) for \(audio.count / 16_000) s: \(turns.count) turns, speech by speaker \(seconds)")
        #expect(seconds.count >= 2)
    }

    /// Enrolling Samantha's solo clip makes her the enrolled slot; the same voice speaks every even sentence of the mixed clip.
    @Test(.enabled(if: realEngineEnabled, Comment(rawValue: gate)))
    func liveEnrolmentRecognisesTheEnrolledVoiceInALongerClip() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.sortformerID)
        let audio = try mixedLong()
        var enrolledShares: [String: Double] = [:]
        var clusters: [String: String] = [:]
        for voice in ["en", "de"] {
            let diarizer = SortformerSpeakerDiarizer(models: manager)
            let cluster = try await diarizer.enroll(samples: try benchClip(voice))
            for frame in frames(audio) { try await diarizer.feed(AudioChunk(samples: frame, format: spec)) }
            let seconds = speechSeconds(try await diarizer.finish())
            let total = seconds.values.reduce(0, +)
            enrolledShares[voice] = (seconds[cluster] ?? 0) / max(total, 1)
            clusters[voice] = cluster
            print("LIVE-ENROL \(voice): enrolled slot \(cluster), share of speech \(enrolledShares[voice]!), all \(seconds)")
        }
        // Each voice's enrolled slot carries a real share of the clip (about half: the voices alternate). Both
        // enrolments land in the first free slot, so the slot id cannot tell them apart; the speech does: enrolling
        // Samantha (the English sentences) gives her slot a larger share than enrolling Anna does.
        for voice in ["en", "de"] { #expect((0.25...0.75).contains(enrolledShares[voice] ?? 0), "\(voice)") }
        #expect((enrolledShares["en"] ?? 0) > (enrolledShares["de"] ?? 1))
        print("LIVE-ENROL slots: \(clusters)")
    }

    @Test(.enabled(if: realEngineEnabled, Comment(rawValue: gate)))
    func offlineEnrolmentMatchesTheEnrolledVoiceInALongerClip() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.diarizerOfflineID)
        let audio = try mixedLong()
        let diarizer = OfflineSpeakerDiarizer(models: manager)
        var you: [String: String?] = [:]
        for voice in ["en", "de"] {
            let outcome = try await diarizer.diarize(samples: audio, enrollment: try benchClip(voice))
            you[voice] = outcome.youCluster
            print("OFFLINE-ENROL \(voice): you = \(outcome.youCluster ?? "nobody"), speech \(speechSeconds(outcome.turns))")
        }
        #expect(you["en"].flatMap { $0 } != nil)
        #expect(you["de"].flatMap { $0 } != nil)
        #expect(you["en"] != you["de"], "the two voices are two different clusters")
    }

    @Test(.enabled(if: realEngineEnabled, Comment(rawValue: gate)))
    func localVqeOutputKeepsTheInputLengthWithAndWithoutAReference() async throws {
        let manager = makeManager()
        try await ensureInstalled(manager, FluidAudioModels.localVqeID)
        let audio = try mixedLong() + [Float](repeating: 0, count: 777)  // not a whole number of hops
        for withReference in [false, true] {
            let enhancer = LocalVqeEnhancer(models: manager)
            var out = 0
            let clock = ContinuousClock()
            let started = clock.now
            for frame in frames(audio) {
                let reference = withReference ? [Float](repeating: 0.01, count: frame.count) : nil
                out += await enhancer.enhance(mic: frame, reference: reference).count
            }
            out += await enhancer.flush().count
            let elapsed = clock.now - started
            let seconds = Double(audio.count) / 16_000
            print("LOCALVQE reference=\(withReference): \(elapsed) for \(seconds) s of audio, state \(await enhancer.state())")
            #expect(out == audio.count)
            #expect(await enhancer.state() == .active)
        }
    }

    /// Nemotron (live engine), Sortformer and LocalVQE at once on the mixed clip, as a meeting runs them.
    @Test(.enabled(if: realEngineEnabled, Comment(rawValue: gate)))
    func realTimeFactorOfNemotronSortformerAndLocalVqeTogether() async throws {
        let manager = makeManager()
        let nemotronID = FluidAudioModels.nemotronID(.multilingual, chunkMs: 1120)
        for id in [nemotronID, FluidAudioModels.sortformerID, FluidAudioModels.localVqeID] { try await ensureInstalled(manager, id) }
        let audio = try mixedLong() + [Float](repeating: 0, count: 16_000 * 2)
        let seconds = Double(audio.count) / 16_000

        @Sendable func nemotron() async throws {
            let engine = NemotronEngine(variant: .multilingual, chunkMs: 1120, models: manager)
            let format = try await engine.prepare(locale: nil)
            let (input, feed) = AsyncStream.makeStream(of: AudioChunk.self)
            let stream = engine.transcribe(input)
            let collector = Task { for try await _ in stream {} }
            for frame in frames(audio) { feed.yield(AudioChunk(samples: frame, format: format)) }
            feed.finish()
            try await engine.finish()
            try await collector.value
        }
        @Sendable func sortformer() async throws {
            let diarizer = SortformerSpeakerDiarizer(models: manager)
            for frame in frames(audio) { try await diarizer.feed(AudioChunk(samples: frame, format: spec)) }
            _ = try await diarizer.finish()
        }
        @Sendable func localVqe() async {
            let enhancer = LocalVqeEnhancer(models: manager)
            for frame in frames(audio) { _ = await enhancer.enhance(mic: frame, reference: nil) }
            _ = await enhancer.flush()
        }

        // Warm every model first so the numbers are steady state, not first-compile.
        try await nemotron()
        try await sortformer()
        await localVqe()

        let clock = ContinuousClock()
        var results: [String: Duration] = [:]
        var started = clock.now
        try await nemotron()
        results["nemotron"] = clock.now - started
        started = clock.now
        try await sortformer()
        results["sortformer"] = clock.now - started
        started = clock.now
        await localVqe()
        results["localvqe"] = clock.now - started
        let togetherStart = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await nemotron() }
            group.addTask { try await sortformer() }
            group.addTask { await localVqe() }
            try await group.waitForAll()
        }
        let together = clock.now - togetherStart
        func rtf(_ duration: Duration) -> Double {
            (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) / seconds
        }
        for (name, duration) in results.sorted(by: { $0.key < $1.key }) {
            print("RTF alone \(name): \(String(format: "%.3f", rtf(duration))) (\(duration) for \(seconds) s)")
        }
        print("RTF together (nemotron + sortformer + localvqe): \(String(format: "%.3f", rtf(together))) (\(together) for \(seconds) s)")
        #expect(rtf(together) < 1, "the three keep up with real time")
    }
}
