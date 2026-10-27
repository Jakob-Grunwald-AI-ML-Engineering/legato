import FluidAudio
import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoFluidAudio

private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

// MARK: Streaming diarizer (Sortformer)

/// Plays the part of the Sortformer model: records what it is fed and answers with scripted segments.
private final class FakeSortformer: SortformerBackend {
    private let state = Mutex((fed: [[Float]](), finished: 0, segments: [SortformerSlotSegment](), failFeed: false))
    func failFeeds() { state.withLock { $0.failFeed = true } }

    var fed: [[Float]] { state.withLock { $0.fed } }
    var finished: Int { state.withLock { $0.finished } }
    func script(_ segments: [SortformerSlotSegment]) { state.withLock { $0.segments = segments } }

    func feed(_ samples: [Float]) throws {
        if state.withLock({ $0.failFeed }) { throw Boom() }
        state.withLock { $0.fed.append(samples) }
    }
    func segments() -> [SortformerSlotSegment] { state.withLock { $0.segments } }
    func finish() throws { state.withLock { $0.finished += 1 } }
}

@Suite("Sortformer speaker diarizer")
struct SortformerSpeakerDiarizerTests {
    private func make(_ backend: FakeSortformer) -> SortformerSpeakerDiarizer {
        SortformerSpeakerDiarizer(backend: backend)
    }

    /// A diarizer whose model is loaded (the first call loads it).
    private func loaded(_ backend: FakeSortformer) async throws -> SortformerSpeakerDiarizer {
        let diarizer = make(backend)
        try await diarizer.feed(AudioChunk(samples: [], format: spec))
        return diarizer
    }

    @Test func clusterIDsNameTheSortformerSlot() {
        #expect(SortformerSpeakerDiarizer.clusterID(slot: 0) == "S0")
        #expect(SortformerSpeakerDiarizer.clusterID(slot: 3) == "S3")
    }

    @Test func turnsAreSortedByStartAndNamedBySlot() async throws {
        let backend = FakeSortformer()
        let diarizer = try await loaded(backend)
        backend.script([
            SortformerSlotSegment(slot: 1, start: 5, end: 6.5),
            SortformerSlotSegment(slot: 0, start: 0.5, end: 2),
            SortformerSlotSegment(slot: 3, start: 2, end: 4.24),
        ])
        #expect(await diarizer.turns() == [
            SpeakerTurn(speaker: "S0", start: 0.5, end: 2),
            SpeakerTurn(speaker: "S3", start: 2, end: 4.24),
            SpeakerTurn(speaker: "S1", start: 5, end: 6.5),
        ])
    }

    @Test func emptyAndBackwardsSegmentsAreNotTurns() async throws {
        let backend = FakeSortformer()
        let diarizer = try await loaded(backend)
        backend.script([
            SortformerSlotSegment(slot: 0, start: 1, end: 1),
            SortformerSlotSegment(slot: 1, start: 4, end: 3),
            SortformerSlotSegment(slot: 2, start: 0, end: 0.5),
        ])
        #expect(await diarizer.turns() == [SpeakerTurn(speaker: "S2", start: 0, end: 0.5)])
    }

    @Test func feedsPassTheSamplesOnInOrder() async throws {
        let backend = FakeSortformer()
        let diarizer = make(backend)
        try await diarizer.feed(AudioChunk(samples: [1, 2, 3], format: spec))
        try await diarizer.feed(AudioChunk(samples: [], format: spec))
        try await diarizer.feed(AudioChunk(samples: [4, 5], format: spec))
        #expect(backend.fed == [[1, 2, 3], [4, 5]])
    }

    @Test func aChunkThatIsNot16kHzMonoIsRefused() async {
        let backend = FakeSortformer()
        let diarizer = make(backend)
        await #expect(throws: FluidAudioEngineError.unsupportedFormat) {
            try await diarizer.feed(AudioChunk(samples: [0, 0], format: AudioFormatSpec(sampleRate: 48_000, channelCount: 1)))
        }
        await #expect(throws: FluidAudioEngineError.unsupportedFormat) {
            try await diarizer.feed(AudioChunk(samples: [0, 0], format: AudioFormatSpec(sampleRate: 16_000, channelCount: 2)))
        }
        #expect(backend.fed.isEmpty)
    }

    @Test func aBackendFailureReachesTheCaller() async {
        let backend = FakeSortformer()
        backend.failFeeds()
        let diarizer = make(backend)
        await #expect(throws: Boom.self) { try await diarizer.feed(AudioChunk(samples: [1], format: spec)) }
    }

    @Test func finishEndsTheAudioOnceAndAnswersWithEveryTurn() async throws {
        let backend = FakeSortformer()
        let diarizer = make(backend)
        backend.script([SortformerSlotSegment(slot: 1, start: 0, end: 2)])
        let first = try await diarizer.finish()
        let second = try await diarizer.finish()
        #expect(first == [SpeakerTurn(speaker: "S1", start: 0, end: 2)])
        #expect(second == first)
        #expect(backend.finished == 1, "finishing twice ends the model's session once")
    }

    @Test func theModelLoadsOnFirstUseNotAtConstruction() async throws {
        let loads = Mutex(0)
        let diarizer = SortformerSpeakerDiarizer {
            loads.withLock { $0 += 1 }
            return FakeSortformer()
        }
        #expect(loads.withLock { $0 } == 0)
        try await diarizer.feed(AudioChunk(samples: [1], format: spec))
        _ = await diarizer.turns()
        try await diarizer.feed(AudioChunk(samples: [1], format: spec))
        #expect(loads.withLock { $0 } == 1)
    }
}

// MARK: Batch diarizer (offline)

/// Plays the part of the offline pipeline: answers per call with the next scripted result and records the hints.
private final class FakeOfflineRunner: OfflineDiarizationRunner {
    private let state = Mutex((results: [Result<DiarizationResult, any Error>](), calls: [(count: Int, hints: DiarizationHints)]()))

    init(_ results: [Result<DiarizationResult, any Error>]) { state.withLock { $0.results = results } }

    var calls: [(count: Int, hints: DiarizationHints)] { state.withLock { $0.calls } }

    func run(audio: [Float], hints: DiarizationHints) async throws -> DiarizationResult {
        let next = state.withLock { s -> Result<DiarizationResult, any Error> in
            s.calls.append((audio.count, hints))
            return s.results.isEmpty ? .failure(Boom()) : s.results.removeFirst()
        }
        return try next.get()
    }
}

private func segment(_ speaker: String, _ start: Float, _ end: Float, _ embedding: [Float]) -> TimedSpeakerSegment {
    TimedSpeakerSegment(speakerId: speaker, embedding: embedding, startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1)
}

private func result(_ segments: [TimedSpeakerSegment], database: [String: [Float]]) -> DiarizationResult {
    DiarizationResult(segments: segments, speakerDatabase: database)
}

@Suite("Offline speaker diarizer")
struct OfflineSpeakerDiarizerTests {
    @Test func turnsAreTheSegmentsInTimeOrderNamedByCluster() async throws {
        let runner = FakeOfflineRunner([
            .success(result([segment("S2", 6, 9, [0, 1]), segment("S1", 0, 5.5, [1, 0])], database: ["S1": [1, 0], "S2": [0, 1]]))
        ])
        let diarizer = OfflineSpeakerDiarizer(runner: runner)
        let turns = try await diarizer.diarize(samples: [Float](repeating: 0.1, count: 160_000))
        #expect(turns == [SpeakerTurn(speaker: "S1", start: 0, end: 5.5), SpeakerTurn(speaker: "S2", start: 6, end: 9)])
    }

    @Test func noSamplesMeansNoTurnsAndNoModelRun() async throws {
        let runner = FakeOfflineRunner([])
        let turns = try await OfflineSpeakerDiarizer(runner: runner).diarize(samples: [])
        #expect(turns.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func aRecordingWithoutSpeechHasNoTurns() async throws {
        let runner = FakeOfflineRunner([.failure(OfflineDiarizationError.noSpeechDetected)])
        let turns = try await OfflineSpeakerDiarizer(runner: runner).diarize(samples: [Float](repeating: 0, count: 160_000))
        #expect(turns.isEmpty)
    }

    @Test func otherFailuresReachTheCaller() async {
        let runner = FakeOfflineRunner([.failure(Boom())])
        await #expect(throws: Boom.self) {
            _ = try await OfflineSpeakerDiarizer(runner: runner).diarize(samples: [Float](repeating: 0, count: 160_000))
        }
    }

    @Test func speakerCountHintsReachTheModel() async throws {
        let runner = FakeOfflineRunner([.success(result([segment("S1", 0, 1, [1, 0])], database: ["S1": [1, 0]]))])
        let hints = DiarizationHints(numSpeakers: nil, minSpeakers: 2, maxSpeakers: 4)
        _ = try await OfflineSpeakerDiarizer(runner: runner, hints: hints).diarize(samples: [Float](repeating: 0.1, count: 16_000))
        #expect(runner.calls.map(\.hints) == [hints])
    }
}

// MARK: Mic enhancement (LocalVQE)

@Suite("Mic and reference alignment")
struct MicReferenceAlignerTests {
    @Test func equalLengthsComeOutSampleForSample() {
        var aligner = MicReferenceAligner()
        aligner.push(mic: [1, 2, 3], reference: [10, 20, 30])
        let pair = aligner.takeAligned()
        #expect(pair.mic == [1, 2, 3])
        #expect(pair.reference == [10, 20, 30])
        #expect(aligner.unmatched == 0)
    }

    @Test func noReferenceIsSilenceOfTheMicsLength() {
        var aligner = MicReferenceAligner()
        aligner.push(mic: [1, 2, 3, 4], reference: nil)
        let pair = aligner.takeAligned()
        #expect(pair.mic == [1, 2, 3, 4])
        #expect(pair.reference == [0, 0, 0, 0])
    }

    @Test func aMicAheadOfItsReferenceWaitsAndPairsByPosition() {
        var aligner = MicReferenceAligner()
        aligner.push(mic: [1, 2, 3, 4], reference: [10, 20])
        let first = aligner.takeAligned()
        #expect(first.mic == [1, 2])
        #expect(first.reference == [10, 20])
        #expect(aligner.unmatched == 2)

        aligner.push(mic: [], reference: [30, 40])
        let second = aligner.takeAligned()
        #expect(second.mic == [3, 4])
        #expect(second.reference == [30, 40])
        #expect(aligner.unmatched == 0)
    }

    @Test func aReferenceAheadOfItsMicWaitsToo() {
        var aligner = MicReferenceAligner()
        aligner.push(mic: [1], reference: [10, 20, 30])
        #expect(aligner.takeAligned().mic == [1])
        #expect(aligner.unmatched == 2)
        aligner.push(mic: [2, 3], reference: [])
        let rest = aligner.takeAligned()
        #expect(rest.mic == [2, 3])
        #expect(rest.reference == [20, 30])
    }

    @Test func theQueueLimitIsOneSecondAt16kHz() {
        #expect(MicReferenceAligner.defaultLimit == 16_000)
    }

    @Test func overflowMeansMoreThanTheLimitUnmatched() {
        var aligner = MicReferenceAligner(limit: 16_000)
        aligner.push(mic: [Float](repeating: 1, count: 16_000), reference: [])
        #expect(!aligner.overflowed, "exactly one second is still fine")
        aligner.push(mic: [1], reference: [])
        #expect(aligner.overflowed)
    }

    @Test func flushingPadsAMicWithoutReferenceAndDropsAnUnmatchedReference() {
        var aligner = MicReferenceAligner()
        aligner.push(mic: [1, 2, 3], reference: [10])
        _ = aligner.takeAligned()
        let end = aligner.takeRemaining()
        #expect(end.mic == [2, 3])
        #expect(end.reference == [0, 0])
        #expect(aligner.unmatched == 0)

        aligner.push(mic: [], reference: [7, 8])
        #expect(aligner.takeRemaining().mic.isEmpty)
        #expect(aligner.unmatched == 0)
    }
}

/// Plays the part of the LocalVQE stream: halves every sample and delays its output by `delay` samples
/// (like the real one's 256-sample hop), so the cleaned signal is recognizable and shorter than the input until flushed.
private final class FakeVqeStream: LocalVqeProcessing {
    private let state = Mutex((
        micIn: [Float](), refIn: [Float](), emitted: 0, calls: 0, failOnCall: Int?.none, flushed: 0
    ))
    let delay: Int

    init(delay: Int = 256, failOnCall: Int? = nil) {
        self.delay = delay
        state.withLock { $0.failOnCall = failOnCall }
    }

    var micIn: [Float] { state.withLock { $0.micIn } }
    var refIn: [Float] { state.withLock { $0.refIn } }
    var calls: Int { state.withLock { $0.calls } }

    func enhance(mic: [Float], reference: [Float]) async throws -> [Float] {
        try state.withLock { s in
            s.calls += 1
            if s.calls == s.failOnCall { throw Boom() }
            s.micIn += mic
            s.refIn += reference
            let ready = max(0, s.micIn.count - delay)
            let out = s.micIn[s.emitted..<ready].map { $0 * 0.5 }
            s.emitted = ready
            return Array(out)
        }
    }

    func flush() async throws -> [Float] {
        state.withLock { s in
            s.flushed += 1
            let out = s.micIn[s.emitted...].map { $0 * 0.5 }
            s.emitted = s.micIn.count
            return Array(out)
        }
    }
}

private func ramp(_ count: Int, from start: Int = 0) -> [Float] {
    (0..<count).map { Float(start + $0 + 1) }
}

@Suite("LocalVQE enhancer")
struct LocalVqeEnhancerTests {
    private func make(_ stream: FakeVqeStream, limit: Int = 16_000) -> LocalVqeEnhancer {
        LocalVqeEnhancer(queueLimit: limit) { stream }
    }

    @Test func cleanedSamplesComeBackInOrderAndTheTotalKeepsTheInputLength() async {
        let stream = FakeVqeStream(delay: 256)
        let enhancer = make(stream)
        var out: [Float] = []
        var fed = 0
        for size in [1_600, 1_600, 777, 1_600, 3_200] {
            out += await enhancer.enhance(mic: ramp(size, from: fed), reference: [Float](repeating: 0, count: size))
            fed += size
        }
        #expect(out.count < fed, "the model delays its output")
        out += await enhancer.flush()
        #expect(out.count == fed)
        #expect(out == ramp(fed).map { $0 * 0.5 }, "sample i out is the cleaned sample i in")
        #expect(await enhancer.state() == .active)
    }

    @Test func micAndReferenceReachTheModelOnTheSameSampleIndex() async {
        let stream = FakeVqeStream(delay: 0)
        let enhancer = make(stream)
        let mic = ramp(5_000)
        let reference = ramp(5_000).map { $0 * -1 }
        // The two sources are chunked differently, as two capture paths are.
        var micAt = 0, refAt = 0
        for (m, r) in [(1_600, 800), (1_600, 2_400), (1_800, 1_800)] {
            _ = await enhancer.enhance(mic: Array(mic[micAt..<micAt + m]), reference: Array(reference[refAt..<refAt + r]))
            micAt += m
            refAt += r
        }
        _ = await enhancer.flush()
        #expect(stream.micIn == mic)
        #expect(stream.refIn == reference)
    }

    @Test func withoutAReferenceTheModelHearsSilenceAndStillCleans() async {
        let stream = FakeVqeStream(delay: 0)
        let enhancer = make(stream)
        var out: [Float] = []
        for index in 0..<4 {
            out += await enhancer.enhance(mic: ramp(1_600, from: index * 1_600), reference: nil)
        }
        out += await enhancer.flush()
        #expect(out == ramp(6_400).map { $0 * 0.5 })
        #expect(stream.refIn == [Float](repeating: 0, count: 6_400))
        #expect(await enhancer.state() == .active)
    }

    @Test func overAQueuedSecondTheRawMicPassesThroughAndTheAppCanSeeIt() async {
        let stream = FakeVqeStream(delay: 256)
        let enhancer = make(stream, limit: 16_000)
        var out = await enhancer.enhance(mic: ramp(1_600), reference: [Float](repeating: 0, count: 1_600))
        // The reference stalls: 1.5 s of mic piles up without one.
        out += await enhancer.enhance(mic: ramp(24_000, from: 1_600), reference: [])
        #expect(await enhancer.state() == .fellBack(.lagging))
        out += await enhancer.enhance(mic: ramp(1_600, from: 25_600), reference: nil)
        out += await enhancer.flush()
        #expect(out.count == 27_200, "no gap, no repeat")
        // The model had delivered 1,344 cleaned samples (it holds back 256); everything after is the raw mic.
        let all = ramp(27_200)
        #expect(Array(out[..<1_344]) == all[..<1_344].map { $0 * 0.5 })
        #expect(Array(out[1_344...]) == Array(all[1_344...]))
    }

    @Test func aModelFailureFallsBackWithoutLosingOrRepeatingASample() async {
        let stream = FakeVqeStream(delay: 256, failOnCall: 3)
        let enhancer = make(stream)
        var out: [Float] = []
        var fed = 0
        for _ in 0..<5 {
            out += await enhancer.enhance(mic: ramp(1_600, from: fed), reference: [Float](repeating: 0, count: 1_600))
            fed += 1_600
        }
        out += await enhancer.flush()
        #expect(await enhancer.state() == .fellBack(.failed("boom")))
        #expect(out.count == fed)
        // The model delivered 2,944 cleaned samples before call 3 failed (it holds back 256); the rest is raw.
        let all = ramp(fed)
        #expect(Array(out[..<2_944]) == all[..<2_944].map { $0 * 0.5 })
        #expect(Array(out[2_944...]) == Array(all[2_944...]))
        #expect(stream.calls == 3, "the model is not called again after it failed")
    }

    @Test func aModelThatCannotLoadPassesTheMicThroughFromTheFirstSample() async {
        let enhancer = LocalVqeEnhancer(queueLimit: 16_000) { throw Boom() }
        let first = await enhancer.enhance(mic: ramp(1_600), reference: nil)
        let second = await enhancer.enhance(mic: ramp(1_600, from: 1_600), reference: nil)
        #expect(first + second == ramp(3_200))
        #expect(await enhancer.state() == .fellBack(.failed("boom")))
    }

    @Test func theModelLoadsOnFirstUseOnly() async {
        let loads = Mutex(0)
        let enhancer = LocalVqeEnhancer(queueLimit: 16_000) {
            loads.withLock { $0 += 1 }
            return FakeVqeStream(delay: 0)
        }
        #expect(loads.withLock { $0 } == 0)
        _ = await enhancer.enhance(mic: ramp(100), reference: nil)
        _ = await enhancer.enhance(mic: ramp(100), reference: nil)
        #expect(loads.withLock { $0 } == 1)
    }

    @Test func flushingAnIdleEnhancerReturnsNothing() async {
        let enhancer = make(FakeVqeStream())
        #expect(await enhancer.flush().isEmpty)
    }
}
