import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAppServices

private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

/// A source the test feeds by hand.
private final class PushSource: AudioSource {
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    let startedFormats = Mutex<[AudioFormatSpec]>([])
    /// Runs as the source starts (to record the order things happen in).
    private let onStart: @Sendable () -> Void
    init(onStart: @escaping @Sendable () -> Void = {}) { self.onStart = onStart }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        onStart()
        startedFormats.withLock { $0.append(format) }
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        continuation.withLock { $0 = cont }
        return stream
    }
    func route() async throws -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func detach() async {}
    func stop() async { continuation.withLock { $0?.finish(); $0 = nil } }
    func push(_ samples: [Float], format: AudioFormatSpec = spec) {
        continuation.withLock { _ = $0?.yield(AudioChunk(samples: samples, format: format)) }
    }
}

/// A push source that also says when it delivers again after a gap (a mic restart, a system tap rebuild).
private final class ResumablePushSource: ResumableAudioSource {
    private let inner = PushSource()
    private let resumeSink: AsyncStream<Void>.Continuation
    let resumptions: AsyncStream<Void>
    init() { (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self) }
    func resume() { resumeSink.yield() }
    func push(_ samples: [Float]) { inner.push(samples) }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { try await inner.start(format: format) }
    func route() async throws -> AsyncStream<AudioChunk> { try await inner.route() }
    func detach() async { await inner.detach() }
    func stop() async {
        await inner.stop()
        resumeSink.finish()
    }
}

/// Collects a stream's samples as they come.
private final class Collector: Sendable {
    private final class Box: Sendable { let all = Mutex<[Float]>([]) }
    private let box = Box()
    var samples: [Float] { box.all.withLock { $0 } }
    let task: Task<Void, Never>
    init(_ stream: AsyncStream<AudioChunk>) {
        let box = self.box
        task = Task { for await c in stream { box.all.withLock { $0 += c.samples } } }
    }
}

/// Halves the mic, slowly: every call takes `delay` of real time. Records how often it was called.
private final class SlowEnhancer: MicEnhancer {
    let calls = Mutex(0)
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    func enhance(mic: [Float], reference: [Float]?) async -> [Float] {
        calls.withLock { $0 += 1 }
        try? await Task.sleep(for: delay)
        return mic.map { $0 * 0.5 }
    }
    func flush() async -> [Float] { [] }
    func state() async -> MicEnhancerState { .active }
}

/// An enhancer that halves the mic, answers a hop late (it holds back `delay` samples until `flush`), records
/// what it was given and can be told to have fallen back.
private final class FakeEnhancer: MicEnhancer {
    struct Call: Equatable { var mic: [Float]; var reference: [Float]? }
    private let state = Mutex((calls: [Call](), held: [Float](), fell: MicEnhancerFallback?.none))
    let delay: Int
    /// Runs in `prepare` (to record the order things happen in).
    let onPrepare: @Sendable () -> Void
    init(delay: Int = 0, onPrepare: @escaping @Sendable () -> Void = {}) {
        self.delay = delay
        self.onPrepare = onPrepare
    }
    var calls: [Call] { state.withLock { $0.calls } }
    func fall(_ reason: MicEnhancerFallback) { state.withLock { $0.fell = reason } }
    func prepare() async { onPrepare() }

    func enhance(mic: [Float], reference: [Float]?) async -> [Float] {
        state.withLock { s in
            s.calls.append(Call(mic: mic, reference: reference))
            s.held += mic.map { $0 * 0.5 }
            let n = max(0, s.held.count - delay)
            defer { s.held.removeFirst(n) }
            return Array(s.held.prefix(n))
        }
    }
    func flush() async -> [Float] { state.withLock { s in defer { s.held = [] }; return s.held } }
    func state() async -> MicEnhancerState { state.withLock { $0.fell.map(MicEnhancerState.fellBack) ?? .active } }
}

private func collect(_ stream: AsyncStream<AudioChunk>) -> Task<[Float], Never> {
    Task { var all: [Float] = []; for await c in stream { all += c.samples }; return all }
}

@Suite struct MicCleaningStageTests {
    @Test func theMicComesOutCleanedInOrderAndTheTailIsFlushedAtTheStop() async throws {
        let enhancer = FakeEnhancer(delay: 100)
        let stage = MicCleaningStage(enhancer: enhancer)
        let source = PushSource()
        let cleaned = stage.mic(source)
        let out = collect(try await cleaned.start(format: spec))
        source.push([Float](repeating: 0.4, count: 1_600))
        source.push([Float](repeating: 0.8, count: 1_600))
        await cleaned.stop()
        let all = await out.value
        #expect(all.count == 3_200, "as many samples out as in, the held-back hop included")
        #expect(all.prefix(1_600).allSatisfy { abs($0 - 0.2) < 1e-6 })
        #expect(all.suffix(1_600).allSatisfy { abs($0 - 0.4) < 1e-6 })
    }

    @Test func withoutAReferenceTheEnhancerGetsNoneAndSoDenoisesOnly() async throws {
        let enhancer = FakeEnhancer()
        let stage = MicCleaningStage(enhancer: enhancer)
        let source = PushSource()
        let cleaned = stage.mic(source)
        let out = collect(try await cleaned.start(format: spec))
        source.push([0.1, 0.2])
        await cleaned.stop()
        _ = await out.value
        #expect(enhancer.calls.allSatisfy { $0.reference == nil })
        #expect(enhancer.calls.contains { $0.mic == [0.1, 0.2] })
    }

    /// What the enhancer's reference side saw, in order: a call with no reference of its own is silence as long as its mic.
    private func effectiveReference(_ calls: [FakeEnhancer.Call]) -> [Float] {
        calls.flatMap { $0.reference ?? [Float](repeating: 0, count: $0.mic.count) }
    }

    @Test func theSystemAudioPassesThroughUnchangedAndAlsoReachesTheEnhancerAsTheReference() async throws {
        let enhancer = FakeEnhancer()
        let now = Mutex<TimeInterval>(100)
        let stage = MicCleaningStage(enhancer: enhancer, clock: { now.withLock { $0 } })
        let mic = PushSource(), system = PushSource()
        let cleanedMic = stage.mic(mic)
        let tapped = stage.reference(system)
        let micOut = collect(try await cleanedMic.start(format: spec))
        let systemOut = collect(try await tapped.start(format: spec))
        // The mic's 10 ms ends at 100.01, the tap's at 100.02: the tap began 10 ms (160 samples) after the mic.
        now.withLock { $0 = 100.01 }
        mic.push([Float](repeating: 0.4, count: 160))
        _ = await eventually { enhancer.calls.count >= 1 }
        now.withLock { $0 = 100.02 }
        system.push([Float](repeating: 0.7, count: 160))
        let delivered = await eventually { enhancer.calls.count >= 2 }
        #expect(delivered)
        await tapped.stop()
        await cleanedMic.stop()
        #expect(await systemOut.value == [Float](repeating: 0.7, count: 160))
        _ = await micOut.value

        let calls = enhancer.calls
        #expect(calls.first == FakeEnhancer.Call(mic: [Float](repeating: 0.4, count: 160), reference: nil), "silence until the tap starts")
        #expect(calls.dropFirst().contains { $0.mic.isEmpty && $0.reference == [Float](repeating: 0.7, count: 160) })
        #expect(effectiveReference(calls) == [Float](repeating: 0, count: 160) + [Float](repeating: 0.7, count: 160))
    }

    @Test func aReferenceThatStartsLaterIsPaddedWithSilenceSoBothLineUp() async throws {
        let enhancer = FakeEnhancer()
        let now = Mutex<TimeInterval>(100)
        let stage = MicCleaningStage(enhancer: enhancer, clock: { now.withLock { $0 } })
        let mic = PushSource(), system = PushSource()
        let cleanedMic = stage.mic(mic)
        let tapped = stage.reference(system)
        let micOut = collect(try await cleanedMic.start(format: spec))
        let systemOut = collect(try await tapped.start(format: spec))
        // The mic's first 100 ms ends at t = 100.1 (so it began at 100.0); the tap's first 100 ms ends at 100.6.
        now.withLock { $0 = 100.1 }
        mic.push([Float](repeating: 0.4, count: 1_600))
        _ = await eventually { enhancer.calls.count >= 1 }
        now.withLock { $0 = 100.6 }
        system.push([Float](repeating: 0.7, count: 1_600))
        _ = await eventually { enhancer.calls.count >= 2 }
        await tapped.stop()
        await cleanedMic.stop()
        _ = await (micOut.value, systemOut.value)

        // The tap began 0.5 s after the mic: 8 000 samples of silence come before its first sample.
        let reference = effectiveReference(enhancer.calls)
        #expect(reference.count == 8_000 + 1_600)
        #expect(reference.prefix(8_000).allSatisfy { $0 == 0 })
        #expect(reference.suffix(1_600).allSatisfy { $0 == 0.7 })
    }

    @Test func aReferenceThatStartedEarlierLosesTheSamplesThatCameBeforeTheMic() async throws {
        let enhancer = FakeEnhancer()
        let now = Mutex<TimeInterval>(100)
        let stage = MicCleaningStage(enhancer: enhancer, clock: { now.withLock { $0 } })
        let mic = PushSource(), system = PushSource()
        let cleanedMic = stage.mic(mic)
        let tapped = stage.reference(system)
        let micOut = collect(try await cleanedMic.start(format: spec))
        let systemOut = collect(try await tapped.start(format: spec))
        // The mic's first 100 ms began at 100.0. The tap's first 200 ms ends at 100.2: it began at 100.0 too, so
        // the 100 ms the mic already played against silence are dropped from the reference.
        now.withLock { $0 = 100.1 }
        mic.push([Float](repeating: 0.4, count: 1_600))
        _ = await eventually { enhancer.calls.count >= 1 }
        now.withLock { $0 = 100.2 }
        system.push([Float](repeating: 0.7, count: 3_200))
        _ = await eventually { enhancer.calls.count >= 2 }
        await tapped.stop()
        await cleanedMic.stop()
        _ = await (micOut.value, systemOut.value)
        #expect(effectiveReference(enhancer.calls).count == 3_200, "mic and reference cover the same 200 ms")
    }

    @Test func whenTheEnhancerFallsBackTheUserIsToldOnce() async throws {
        let enhancer = FakeEnhancer()
        let stage = MicCleaningStage(enhancer: enhancer)
        let source = PushSource()
        let cleaned = stage.mic(source)
        let out = collect(try await cleaned.start(format: spec))
        enhancer.fall(.lagging)
        source.push([0.1])
        source.push([0.2])
        source.push([0.3])
        await cleaned.stop()
        _ = await out.value
        var notices: [String] = []
        for await n in stage.notices { notices.append(n) }
        #expect(notices.count == 1)
        #expect(notices.first?.localizedCaseInsensitiveContains("microphone") == true)
    }

    @Test func aFormatTheEnhancerCannotTakePassesTheMicThroughRawWithANotice() async throws {
        let enhancer = FakeEnhancer()
        let stage = MicCleaningStage(enhancer: enhancer)
        let source = PushSource()
        let cleaned = stage.mic(source)
        let other = AudioFormatSpec(sampleRate: 48_000, channelCount: 1)
        let out = collect(try await cleaned.start(format: other))
        source.push([0.1, 0.2, 0.3], format: other)
        await cleaned.stop()
        #expect(await out.value == [0.1, 0.2, 0.3])
        #expect(enhancer.calls.isEmpty)
        var notices: [String] = []
        for await n in stage.notices { notices.append(n) }
        #expect(notices.count == 1)
    }

    // MARK: Ready before the first sample (A1)

    @Test func theModelIsLoadedBeforeTheMicStartsSoNoAudioQueuesBehindTheLoad() async throws {
        let order = Mutex<[String]>([])
        let enhancer = FakeEnhancer(onPrepare: { order.withLock { $0.append("prepare") } })
        let stage = MicCleaningStage(enhancer: enhancer)
        let source = PushSource(onStart: { order.withLock { $0.append("mic started") } })
        let cleaned = stage.mic(source)
        _ = try await cleaned.start(format: spec)
        #expect(order.withLock { $0 } == ["prepare", "mic started"])
        await cleaned.stop()
    }

    // MARK: Falling behind (A3)

    @Test func aSlowEnhancerWithMoreThanASecondQueuedFallsBackToTheRawMicWithANotice() async throws {
        let enhancer = SlowEnhancer(delay: .milliseconds(30))
        let stage = MicCleaningStage(enhancer: enhancer)
        let source = PushSource()
        let cleaned = stage.mic(source)
        let out = collect(try await cleaned.start(format: spec))
        for _ in 0..<40 { source.push([Float](repeating: 0.4, count: 1_600)) }  // 4 s at once: the model cannot keep up
        await cleaned.stop()
        let all = await out.value
        #expect(all.count == 64_000, "nothing lost, nothing repeated")
        // Cleaned while it kept up (how long that is depends on scheduling), then the raw mic for good.
        let firstRaw = all.firstIndex { $0 == 0.4 } ?? all.count
        #expect(firstRaw <= 16_000, "no more than a second went through the slow model")
        #expect(all[..<firstRaw].allSatisfy { abs($0 - 0.2) < 1e-6 })
        #expect(all[firstRaw...].allSatisfy { $0 == 0.4 })
        #expect(enhancer.calls.withLock { $0 } < 10, "the backlog is not fed to the slow model")
        var notices: [String] = []
        for await n in stage.notices { notices.append(n) }
        #expect(notices.count == 1)
        #expect(notices.first?.localizedCaseInsensitiveContains("fell behind") == true)
    }

    // MARK: Resumptions (A4)

    @Test func aSystemTapThatRebuildsIsLinedUpAgainByTheClock() async throws {
        let enhancer = FakeEnhancer()
        let now = Mutex<TimeInterval>(100)
        let stage = MicCleaningStage(enhancer: enhancer, clock: { now.withLock { $0 } })
        let mic = PushSource(), system = ResumablePushSource()
        let cleanedMic = stage.mic(mic)
        let tapped = stage.reference(system)
        let micOut = collect(try await cleanedMic.start(format: spec))
        let systemOut = Collector(try await tapped.start(format: spec))
        let tapResumed = (tapped as! any ResumableAudioSource).resumptions
        func micChunk(at t: TimeInterval) async {
            let before = enhancer.calls.count
            now.withLock { $0 = t }
            mic.push([Float](repeating: 0.4, count: 1_600))
            _ = await eventually { enhancer.calls.count > before }
        }
        func referenceChunk(_ value: Float, at t: TimeInterval) async {
            let before = systemOut.samples.count
            now.withLock { $0 = t }
            system.push([Float](repeating: value, count: 1_600))
            _ = await eventually { systemOut.samples.count > before }
        }
        await micChunk(at: 100.1)  // the mic began at 100.0
        await referenceChunk(0.7, at: 100.2)  // 0.1-0.2 s
        for i in 2...9 { await micChunk(at: 100 + 0.1 * Double(i)) }  // the tap is rebuilding: 0.2-0.9 s has no reference
        system.resume()
        for await _ in tapResumed { break }
        await referenceChunk(0.9, at: 101.0)  // back: 0.9-1.0 s
        await micChunk(at: 101.0)
        await tapped.stop()
        await cleanedMic.stop()
        _ = await micOut.value

        let reference = effectiveReference(enhancer.calls)
        try #require(reference.count >= 16_000)
        #expect(reference[1_600..<3_200].allSatisfy { $0 == 0.7 })
        #expect(reference[3_200..<14_400].allSatisfy { $0 == 0 }, "the rebuild is silence on the reference")
        #expect(reference[14_400..<16_000].allSatisfy { $0 == 0.9 }, "the audio after the rebuild pairs with the mic of the same moment")
    }

    @Test func aMicThatRestartsSkipsTheReferenceOfTheTimeItWasAway() async throws {
        let enhancer = FakeEnhancer()
        let now = Mutex<TimeInterval>(100)
        let stage = MicCleaningStage(enhancer: enhancer, clock: { now.withLock { $0 } })
        let mic = ResumablePushSource(), system = PushSource()
        let cleanedMic = stage.mic(mic)
        let tapped = stage.reference(system)
        let micOut = collect(try await cleanedMic.start(format: spec))
        let systemOut = Collector(try await tapped.start(format: spec))
        let micResumed = (cleanedMic as! any ResumableAudioSource).resumptions
        func micChunk(at t: TimeInterval) async {
            let before = enhancer.calls.count
            now.withLock { $0 = t }
            mic.push([Float](repeating: 0.4, count: 1_600))
            _ = await eventually { enhancer.calls.count > before }
        }
        /// Reference chunk `k` covers k/10 to (k+1)/10 s and has the value k/10.
        func referenceChunk(_ k: Int) async {
            let before = systemOut.samples.count
            now.withLock { $0 = 100.1 + 0.1 * Double(k) }
            system.push([Float](repeating: Float(k) / 10, count: 1_600))
            #expect(await eventually { systemOut.samples.count > before })
            // ReferenceTap enqueues the copy before its output collector can acknowledge it.
        }
        await micChunk(at: 100.1)  // 0-0.1 s
        for k in 1...5 { await referenceChunk(k) }  // the mic is away from 0.1 s to 0.6 s
        mic.resume()
        for await _ in micResumed { break }
        await referenceChunk(6)
        await micChunk(at: 100.7)  // back: 0.6-0.7 s
        for k in 7...9 {
            await referenceChunk(k)
            await micChunk(at: 100.1 + 0.1 * Double(k))
        }
        await tapped.stop()
        await cleanedMic.stop()
        _ = await micOut.value

        // The fifth mic chunk (samples 6 400-8 000 of the mic) is 0.9-1.0 s: it must meet reference chunk 9.
        let reference = effectiveReference(enhancer.calls)
        try #require(reference.count >= 8_000)
        #expect(reference[6_400..<8_000].allSatisfy { abs($0 - 0.9) < 1e-6 })
    }

    @Test func startingAndStoppingAreForwardedToTheRealSources() async throws {
        let stage = MicCleaningStage(enhancer: FakeEnhancer())
        let mic = PushSource(), system = PushSource()
        let cleaned = stage.mic(mic), tapped = stage.reference(system)
        let other = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
        _ = try await cleaned.start(format: other)
        _ = try await tapped.start(format: other)
        #expect(mic.startedFormats.withLock { $0 } == [other])
        #expect(system.startedFormats.withLock { $0 } == [other])
        await tapped.stop()
        await cleaned.stop()
    }
}

/// Polls `condition` until it holds or a moment passes.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
