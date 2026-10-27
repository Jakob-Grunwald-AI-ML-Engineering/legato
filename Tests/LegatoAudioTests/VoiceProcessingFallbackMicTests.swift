import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoAudio

private struct StartFailed: Error {}

/// A microphone the test drives; remembers whether it was asked for voice processing.
private final class FakeMic: ResumableAudioSource {
    let voiceProcessing: Bool
    private let failStart: Bool
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let stops = Mutex(0)
    private let resumeSink: AsyncStream<Void>.Continuation
    let resumptions: AsyncStream<Void>
    var stopCount: Int { stops.withLock { $0 } }

    init(voiceProcessing: Bool, failStart: Bool = false) {
        self.voiceProcessing = voiceProcessing
        self.failStart = failStart
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self)
    }

    func push(_ level: Float, seconds: Double = 0.1) {
        let count = Int(16_000 * seconds)
        let chunk = AudioChunk(samples: Array(repeating: level, count: count), format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        continuation.withLock { _ = $0?.yield(chunk) }
    }
    func resume() { resumeSink.yield() }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        if failStart { throw StartFailed() }
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        continuation.withLock { $0 = cont }
        return stream
    }
    func route() async throws -> AsyncStream<AudioChunk> { throw MicSourceError.notArmed }
    func detach() async {}
    func stop() async {
        stops.withLock { $0 += 1 }
        continuation.withLock { $0?.finish(); $0 = nil }
    }
}

/// Makes the mics in order of `plan` (voice processing flag, whether its start fails) and keeps them.
private final class Factory: Sendable {
    private let plan: Mutex<[(vp: Bool, fail: Bool)]>
    let made = Mutex<[FakeMic]>([])
    init(_ plan: [(vp: Bool, fail: Bool)]) { self.plan = Mutex(plan) }
    func make(_ vp: Bool) -> any AudioSource {
        let next = plan.withLock { $0.isEmpty ? (vp: vp, fail: false) : $0.removeFirst() }
        let mic = FakeMic(voiceProcessing: vp, failStart: next.fail)
        made.withLock { $0.append(mic) }
        return mic
    }
    var mics: [FakeMic] { made.withLock { $0 } }
}

private final class Got: Sendable {
    private let list = Mutex<[Float]>([])
    func append(_ v: Float) { list.withLock { $0.append(v) } }
    var values: [Float] { list.withLock { $0 } }
}

/// Records what an `AsyncStream` yields, so a test can poll instead of waiting for a value that may never come.
private final class Tally<T: Sendable>: Sendable {
    private let list = Mutex<[T]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)
    init(_ stream: AsyncStream<T>) {
        let t = Task { for await v in stream { list.withLock { $0.append(v) } } }
        task.withLock { $0 = t }
    }
    var values: [T] { list.withLock { $0 } }
    deinit { task.withLock { $0 }?.cancel() }
}

private let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The decisions are pure (`MicSilenceGuard`); these cover the wiring around real microphones, with fakes.
/// The real voice-processing failure (AirPods) is hardware-only.
@Suite struct VoiceProcessingFallbackMicTests {
    private func collect(_ stream: AsyncStream<AudioChunk>) -> (Got, Task<Void, Never>) {
        let got = Got()
        let task = Task { for await chunk in stream { got.append(chunk.samples[0]) } }
        return (got, task)
    }

    @Test func aWorkingVoiceProcessingMicIsLeftAlone() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(voiceProcessing: true, make: { factory.make($0) })
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        factory.mics[0].push(0.3)
        #expect(await eventually { got.values == [0.3] })
        #expect(factory.mics.count == 1 && factory.mics[0].voiceProcessing)
        await source.stop()
        await reader.value
    }

    @Test func aVoiceProcessingStartThatFailsFallsBackAndSaysSo() async throws {
        let factory = Factory([(vp: true, fail: true)])
        let source = VoiceProcessingFallbackMic(voiceProcessing: true, make: { factory.make($0) })
        let notices = Tally(source.notices)

        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)

        #expect(factory.mics.map(\.voiceProcessing) == [true, false])
        #expect(await eventually { notices.values == [VoiceProcessingFallbackMic.notice] })
        factory.mics[1].push(0.4)
        #expect(await eventually { got.values == [0.4] })
        await source.stop()
        await reader.value
    }

    @Test func aMicThatStaysSilentIsRestartedWithoutVoiceProcessingOnTheSameStream() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: true, guardian: MicSilenceGuard(window: 1, peakThreshold: 0.01), make: { factory.make($0) })
        let notices = Tally(source.notices), resumptions = Tally(source.resumptions)
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)

        for _ in 0..<10 { factory.mics[0].push(0.0007) } // one second of near-silence
        #expect(await eventually { notices.values == [VoiceProcessingFallbackMic.notice] })
        #expect(await eventually { resumptions.values.count == 1 }, "the meeting is told to fill the gap")
        #expect(factory.mics.map(\.voiceProcessing) == [true, false])
        #expect(factory.mics[0].stopCount == 1, "the broken engine is stopped")

        factory.mics[1].push(0.5)
        #expect(await eventually { got.values.last == 0.5 })
        await source.stop()
        await reader.value
        #expect(factory.mics[1].stopCount >= 1)
    }

    @Test func aMicWithoutVoiceProcessingIsNeverSwitched() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, guardian: MicSilenceGuard(window: 1), make: { factory.make($0) })
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        for _ in 0..<30 { factory.mics[0].push(0) }
        #expect(await eventually { got.values.count == 30 })
        #expect(factory.mics.count == 1)
        await source.stop()
        await reader.value
    }

    @Test func aRestartOfTheUnderlyingMicIsPassedOn() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(voiceProcessing: true, make: { factory.make($0) })
        let resumptions = Tally(source.resumptions)
        _ = try await source.start(format: format)
        factory.mics[0].resume() // MicSource rebuilt its engine after a device change
        #expect(await eventually { resumptions.values.count == 1 })
        await source.stop()
    }

    @Test func aFailingStartWithoutVoiceProcessingStillThrows() async {
        let factory = Factory([(vp: false, fail: true)])
        let source = VoiceProcessingFallbackMic(voiceProcessing: false, make: { factory.make($0) })
        await #expect(throws: StartFailed.self) { _ = try await source.start(format: format) }
    }
}
