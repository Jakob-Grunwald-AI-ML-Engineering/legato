import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoAudio

/// A microphone the test controls: `start` waits for the gate when asked to, and the test pushes chunks.
private final class ScriptedMic: AudioSource {
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let stops = Mutex(0)
    private let gate: AsyncStream<Void>?
    var stopCount: Int { stops.withLock { $0 } }

    init(gate: AsyncStream<Void>? = nil) { self.gate = gate }

    func push(_ value: Float) {
        let chunk = AudioChunk(samples: [value], format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        continuation.withLock { _ = $0?.yield(chunk) }
    }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        if let gate { for await _ in gate { break } }
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

/// Hands out the mics a test prepared, in order.
private final class MicFactory: Sendable {
    private let mics: Mutex<[ScriptedMic]>
    let made = Mutex<[ScriptedMic]>([])
    init(_ mics: [ScriptedMic]) { self.mics = Mutex(mics) }
    func make() -> any AudioSource {
        let next = mics.withLock { $0.removeFirst() }
        made.withLock { $0.append(next) }
        return next
    }
}

private let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite struct ResumableMicSourceTests {
    @Test func theStreamCarriesOnAcrossARestartAndReportsTheResumption() async throws {
        let first = ScriptedMic(), second = ScriptedMic()
        let factory = MicFactory([first, second])
        let source = ResumableMicSource(make: { factory.make() })
        let stream = try await source.start(format: format)
        let got = Mutex<[Float]>([])
        let reader = Task { for await chunk in stream { got.withLock { $0.append(chunk.samples[0]) } } }
        var resumptions = source.resumptions.makeAsyncIterator()

        first.push(1)
        #expect(await eventually { got.withLock { $0 } == [1] })
        try await source.restart()
        #expect(first.stopCount == 1)
        await resumptions.next()
        second.push(2)
        #expect(await eventually { got.withLock { $0 } == [1, 2] })

        await source.stop()
        await reader.value
        #expect(second.stopCount == 1)
    }

    @Test func aStopDuringARestartLeavesNoMicrophoneRunning() async throws {
        let first = ScriptedMic()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let second = ScriptedMic(gate: gate)
        let factory = MicFactory([first, second])
        let source = ResumableMicSource(make: { factory.make() })
        _ = try await source.start(format: format)

        let restart = Task { try await source.restart() }
        #expect(await eventually { factory.made.withLock { $0.count } == 2 })  // the new mic is starting
        await source.stop()
        open.yield()  // ... and only now finishes starting

        await #expect(throws: MicSourceError.notArmed) { try await restart.value }
        #expect(second.stopCount == 1, "the engine the restart created is stopped again")
    }
}
