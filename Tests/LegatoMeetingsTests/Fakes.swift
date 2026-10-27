import Foundation
import Synchronization
import LegatoCore
@testable import LegatoMeetings

let recFormat = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("legato-meetings-\(UUID().uuidString)", isDirectory: true)
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A settable meeting clock, in seconds.
final class TestClock: Sendable {
    private let value = Mutex<TimeInterval>(0)
    var now: TimeInterval {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// A source the test feeds by hand.
final class ScriptedSource: ResumableAudioSource {
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let stops = Mutex(0)
    private let starts = Mutex(0)
    private let onStart: @Sendable () -> Void
    private let resumeSink: AsyncStream<Void>.Continuation
    let resumptions: AsyncStream<Void>
    var stopCount: Int { stops.withLock { $0 } }
    var startCount: Int { starts.withLock { $0 } }

    /// - Parameter onStart: runs inside `start`, e.g. to let the test clock move the way a slow start would.
    init(onStart: @escaping @Sendable () -> Void = {}) {
        self.onStart = onStart
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func push(_ chunk: AudioChunk) { continuation.withLock { _ = $0?.yield(chunk) } }
    /// The source delivers audio again after a gap.
    func resume() { resumeSink.yield() }
    /// The source's chunk stream ends without `stop()` (a failed restart).
    func endStream() { continuation.withLock { $0?.finish(); $0 = nil } }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        continuation.withLock { $0 = cont }
        return stream
    }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        starts.withLock { $0 += 1 }
        onStart()
        return makeStream()
    }
    func route() async throws -> AsyncStream<AudioChunk> { makeStream() }
    func detach() async { continuation.withLock { $0?.finish(); $0 = nil } }
    func stop() async {
        stops.withLock { $0 += 1 }
        continuation.withLock { $0?.finish(); $0 = nil }
        resumeSink.finish()
    }
}

/// An engine that records the audio it is given and emits what the test tells it to.
final class RecordingEngine: DictationEngine {
    let id: String
    private let received = Mutex<[AudioChunk]>([])
    private let results = Mutex<AsyncThrowingStream<TranscriptEvent, Error>.Continuation?>(nil)
    private let finishes = Mutex(0)
    private let locales = Mutex<[Locale?]>([])

    init(id: String = "fake") { self.id = id }

    /// The locale of every `prepare` call.
    var preparedLocales: [Locale?] { locales.withLock { $0 } }

    var chunks: [AudioChunk] { received.withLock { $0 } }
    var finishCount: Int { finishes.withLock { $0 } }
    func emit(_ event: TranscriptEvent) { results.withLock { _ = $0?.yield(event) } }

    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec {
        locales.withLock { $0.append(locale) }
        return recFormat
    }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, cont) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        results.withLock { $0 = cont }
        let task = Task {
            for await chunk in input { received.withLock { $0.append(chunk) } }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }
    func finish() async throws { finishes.withLock { $0 += 1 } }
}

final class RecordingSink: MeetingAudioSink {
    enum Call: Equatable {
        case write(TranscriptEvent.Stream, [Float])
        case silence(TranscriptEvent.Stream, TimeInterval)
        case finish
    }
    private let log = Mutex<[Call]>([])
    var calls: [Call] { log.withLock { $0 } }

    func write(_ chunk: AudioChunk, stream: TranscriptEvent.Stream) async throws {
        log.withLock { $0.append(.write(stream, chunk.samples)) }
    }
    func writeSilence(seconds: TimeInterval, stream: TranscriptEvent.Stream) async throws {
        log.withLock { $0.append(.silence(stream, seconds)) }
    }
    func finish() async throws { log.withLock { $0.append(.finish) } }
}

func tone(_ count: Int, _ value: Float = 0.5) -> AudioChunk {
    AudioChunk(samples: Array(repeating: value, count: count), format: recFormat)
}

func finalEvent(_ text: String, _ range: Range<TimeInterval>? = nil, stream: TranscriptEvent.Stream = .mic) -> TranscriptEvent {
    TranscriptEvent(stream: stream, text: text, isFinal: true, range: range)
}

struct EngineBoom: Error {}

/// An engine whose result stream fails at once; it records whether its audio input was ended.
final class FailingEngine: DictationEngine {
    let id = "failing"
    private let state = Mutex((received: 0, inputEnded: false))
    var received: Int { state.withLock { $0.received } }
    var inputEnded: Bool { state.withLock { $0.inputEnded } }

    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec { recFormat }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        Task {
            for await _ in input { state.withLock { $0.received += 1 } }
            state.withLock { $0.inputEnded = true }
        }
        return AsyncThrowingStream { $0.finish(throwing: EngineBoom()) }
    }
    func finish() async throws {}
}

/// An engine that reads its audio only once the test opens the gate (a transcriber that lags behind).
final class GatedEngine: DictationEngine {
    let id = "gated"
    private let gate = Mutex(false)
    private let got = Mutex<[AudioChunk]>([])
    var chunks: [AudioChunk] { got.withLock { $0 } }
    func open() { gate.withLock { $0 = true } }

    func installAssets(locale: Locale?) -> AsyncStream<Double> { AsyncStream { $0.finish() } }
    func prepare(locale: Locale?) async throws -> AudioFormatSpec { recFormat }
    func transcribe(_ input: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, cont) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let task = Task {
            while !gate.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
            for await chunk in input { got.withLock { $0.append(chunk) } }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
        return stream
    }
    func finish() async throws {}
}
