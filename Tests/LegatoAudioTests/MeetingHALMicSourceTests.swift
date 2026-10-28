#if os(macOS)
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAudio

private final class TestHALLease: MeetingHALInputLease {
    let calls = Mutex<[String]>([])
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func start() throws {
        calls.withLock { $0.append("start") }
        if fails { throw MicSourceError.invalidInputFormat }
    }
    func stop() { calls.withLock { $0.append("stop") } }
}

@Suite struct MeetingHALMicSourceTests {
    @Test func failedStartStopsThePartiallyStartedNativeLease() async {
        let lease = TestHALLease(fails: true)
        let source = MeetingHALMicSource(device: 90) { _, _, _ in lease }
        await #expect(throws: MicSourceError.invalidInputFormat) {
            try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        }
        #expect(lease.calls.withLock { $0 } == ["start", "stop"])
    }

    @Test func pinnedDeviceAndRequestedOutputFormatReachTheNativeLease() async throws {
        let lease = TestHALLease()
        let seen = Mutex<[UInt32]>([])
        let source = MeetingHALMicSource(device: 176) { device, format, router in
            #expect(format == AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
            seen.withLock { $0.append(device) }
            return lease
        }
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        await source.stop(); await source.stop()
        #expect(seen.withLock { $0 } == [176])
        #expect(lease.calls.withLock { $0 } == ["start", "stop"])
        await #expect(throws: MicSourceError.notArmed) { try await source.route() }
    }

    @Test func aQueuedOldDeviceCallbackCannotCloseTheReplacementStream() async throws {
        let routers = Mutex<[TapRouter]>([])
        let source = MeetingHALMicSource(device: 90) { _, _, router in
            routers.withLock { $0.append(router) }
            return TestHALLease()
        }
        let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
        _ = try await source.start(format: format)
        let replacement = try await source.start(format: format)
        let callbacks = routers.withLock { $0 }
        callbacks[0].setSink(nil) // A notification already queued when the old listener was removed.
        callbacks[1].handle(AudioChunk(samples: [0.25], format: format))
        var iterator = replacement.makeAsyncIterator()
        #expect(await iterator.next()?.samples == [0.25])
        await source.stop()
    }

    @Test func replacementStopsThePreviousLeaseBeforeStartingAnother() async throws {
        let first = TestHALLease(), second = TestHALLease()
        let next = Mutex(0)
        let source = MeetingHALMicSource(device: 90) { _, _, _ in
            let index = next.withLock { i in defer { i += 1 }; return i }
            if index == 1 { #expect(first.calls.withLock { $0 } == ["start", "stop"]) }
            return index == 0 ? first : second
        }
        let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
        _ = try await source.start(format: format)
        _ = try await source.start(format: format)
        await source.stop()
        #expect(second.calls.withLock { $0 } == ["start", "stop"])
    }
}
#endif
