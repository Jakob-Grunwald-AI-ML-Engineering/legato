#if os(macOS)
import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoAudio

private struct TapBuildFailed: Error {}
private actor TapBuildGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private final class TestTap: Sendable {
    let callback: @Sendable (AudioChunk) -> Void
    let closed = Mutex(false)
    init(_ callback: @escaping @Sendable (AudioChunk) -> Void) { self.callback = callback }
    func lease() -> SystemAudioTapLease { SystemAudioTapLease { [self] in closed.withLock { $0 = true } } }
    func emit(_ value: Float) {
        guard !closed.withLock({ $0 }) else { return }
        callback(AudioChunk(samples: [value], format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1)))
    }
}
private actor RecoveredChunks {
    var samples: [Float] = []
    func append(_ chunk: AudioChunk) { samples += chunk.samples }
}

@Suite struct SystemAudioRecoveryTests {
    static let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    @Test func failedRebuildIsRetriedByPollingAndOriginalStreamRecovers() async throws {
        let builds = Mutex(0), taps = Mutex<[TestTap]>([]), now = Mutex(0.0)
        let source = SystemAudioSource(clock: { now.withLock { $0 } }, build: { _, callback in
            let attempt = builds.withLock { $0 += 1; return $0 }
            if attempt == 2 { throw TapBuildFailed() }
            let tap = TestTap(callback); taps.withLock { $0.append(tap) }; return tap.lease()
        })
        let stream = try await source.start(format: Self.format)
        let chunks = RecoveredChunks()
        let reader = Task { for await chunk in stream { await chunks.append(chunk) } }
        taps.withLock { $0.last }?.emit(0.2)
        await source.rebuild()
        now.withLock { $0 = 1 }
        await source.rebuildIfRateChanged()
        taps.withLock { $0.last }?.emit(0.6)
        await source.stop(); await reader.value
        #expect(builds.withLock { $0 } == 3)
        #expect(await chunks.samples == [0.2, 0.6])
    }
    @Test func staleRebuildCannotReplaceOrCloseRestartedTap() async throws {
        let builds = Mutex(0), taps = Mutex<[Int: TestTap]>([:]), gate = TapBuildGate()
        let source = SystemAudioSource(clock: { 0 }, build: { _, callback in
            let attempt = builds.withLock { $0 += 1; return $0 }
            if attempt == 2 { await gate.wait() }
            let tap = TestTap(callback); taps.withLock { $0[attempt] = tap }; return tap.lease()
        })
        _ = try await source.start(format: Self.format)
        let rebuild = Task { await source.rebuild() }
        let deadline = ContinuousClock.now + .seconds(30)
        while await !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
        await source.stop()
        let stream = try await source.start(format: Self.format)
        let chunks = RecoveredChunks()
        let reader = Task { for await chunk in stream { await chunks.append(chunk) } }
        await gate.open(); await rebuild.value
        taps.withLock { $0[3] }?.emit(0.6)
        #expect(taps.withLock { $0[2]?.closed.withLock { $0 } } == true)
        #expect(taps.withLock { $0[3]?.closed.withLock { $0 } } == false)
        await source.stop(); await reader.value
        #expect(await chunks.samples == [0.6])
    }
}
#endif
