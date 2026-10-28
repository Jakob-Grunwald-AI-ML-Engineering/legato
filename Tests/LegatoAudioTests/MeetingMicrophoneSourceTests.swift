import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoAudio

private actor MeetingStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private final class MeetingInput: AudioSource {
    let gate: MeetingStartGate?
    init(gate: MeetingStartGate? = nil) { self.gate = gate }
    let sink = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    let format = Mutex(AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        if let gate { await gate.wait() }
        self.format.withLock { $0 = format }
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        sink.withLock { $0 = continuation }
        return stream
    }
    func push(_ value: Float, samples: Int = 320) {
        let format = format.withLock { $0 }
        sink.withLock { $0?.yield(AudioChunk(samples: Array(repeating: value, count: samples), format: format)) }
    }
    func end() { sink.withLock { $0?.finish() } }
    func route() async throws -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func detach() async {}
    func stop() async { sink.withLock { $0?.finish(); $0 = nil } }
}

private actor MicrophoneChunks {
    var values: [AudioChunk] = []
    var finished = false
    func add(_ chunk: AudioChunk) { values.append(chunk) }
    func finish() { finished = true }
}

@Suite struct MeetingMicrophoneSourceTests {
    static let devices = [MeetingMicrophoneDevice(id: 1, uid: "a", name: "Mac"), MeetingMicrophoneDevice(id: 2, uid: "b", name: "Headset")]
    private func waitForBuffers(_ source: MeetingMicrophoneSource, count: Int) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(30)
        while await source.bufferedInputCount != count, clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await source.bufferedInputCount == count)
    }
    @Test func allInputsShareOneTimelineAndSum() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .all, devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        first.push(0.2); second.push(0.3)
        try await waitForBuffers(source, count: 2)
        let chunk = await source.render(samples: 320)
        #expect(chunk.samples.count == 320)
        #expect(abs((chunk.samples.first ?? 0) - 0.5) < 0.0001)
        await source.stop()
    }
    @Test func requested48kMonoFormatIsPreserved() async throws {
        let mic = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .device("a"), devices: Self.devices, automaticTicks: false, makeSource: { _ in mic })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 48_000, channelCount: 1))
        mic.push(0.4, samples: 960)
        try await waitForBuffers(source, count: 1)
        let chunk = await source.render(samples: 960)
        #expect(chunk.format == AudioFormatSpec(sampleRate: 48_000, channelCount: 1))
        #expect(chunk.samples == Array(repeating: Float(0.4), count: 960))
        await source.stop()
    }
    @Test func normalQuarterSecondDriverBufferIsNotTruncated() async throws {
        let mic = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .all, devices: [Self.devices[0]], automaticTicks: false, makeSource: { _ in mic })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        mic.push(0.25, samples: 4096)
        try await waitForBuffers(source, count: 1)
        var samples: [Float] = []
        for _ in 0..<12 { samples += await source.render(samples: 320).samples }
        #expect(samples == Array(repeating: Float(0.25), count: 3840))
        await source.stop()
    }
    @Test func livePinnedSwitchKeepsOutputOpenAndNeverIncludesOldInput() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .device("a"), devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        let stream = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        let chunks = MicrophoneChunks()
        let reader = Task { for await chunk in stream { await chunks.add(chunk) }; await chunks.finish() }
        first.push(0.2); try await waitForBuffers(source, count: 1)
        #expect(await source.render(samples: 320).samples.first == 0.2)
        await source.update(selection: .device("b"), devices: Self.devices)
        first.push(0.9); second.push(0.4)
        try await waitForBuffers(source, count: 1)
        #expect(await source.render(samples: 320).samples.first == 0.4)
        #expect(await chunks.finished == false)
        await source.stop(); await reader.value
        #expect(await chunks.finished)
    }
    @Test func autoChoosesLoudestAndRequiresSustainedAdvantageBeforeSwitch() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .auto, devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        for _ in 0..<60 {
            first.push(0.4); second.push(0.1); try await waitForBuffers(source, count: 2)
            _ = await source.render(samples: 320)
        }
        #expect(await source.activeDeviceUID == "a")
        first.push(0.1); second.push(0.9); try await waitForBuffers(source, count: 2)
        _ = await source.render(samples: 320)
        #expect(await source.activeDeviceUID == "a")
        for _ in 0..<35 {
            first.push(0.1); second.push(0.9); try await waitForBuffers(source, count: 2)
            _ = await source.render(samples: 320)
        }
        #expect(await source.activeDeviceUID == "b")
        await source.stop()
    }
    @Test func disconnectedPinnedDeviceProducesSilenceWithoutDefaultFallback() async throws {
        let made = Mutex<[String]>([])
        let source = MeetingMicrophoneSource(selection: .device("missing"), devices: Self.devices, automaticTicks: false, makeSource: { device in made.withLock { $0.append(device.uid) }; return MeetingInput() })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        #expect(made.withLock { $0 }.isEmpty)
        #expect(await source.render(samples: 320).samples == Array(repeating: Float.zero, count: 320))
        await source.stop()
    }
    @Test func hardwareRefreshRetriesEndedInputOnSameDevice() async throws {
        let first = MeetingInput(), replacement = MeetingInput()
        let count = Mutex(0)
        let source = MeetingMicrophoneSource(selection: .all, devices: [Self.devices[0]], automaticTicks: false, makeSource: { _ in count.withLock { $0 += 1; return $0 == 1 ? first : replacement } })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        first.push(0.2); try await waitForBuffers(source, count: 1)
        first.end(); try await waitForBuffers(source, count: 0)
        await source.update(selection: .all, devices: [Self.devices[0]])
        #expect(count.withLock { $0 } == 2)
        replacement.push(0.6); try await waitForBuffers(source, count: 1)
        #expect(await source.render(samples: 320).samples.first == 0.6)
        await source.stop()
    }
    @Test func allModeProtectsAgainstClipping() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .all, devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        first.push(0.8); second.push(0.8); try await waitForBuffers(source, count: 2)
        #expect(await source.render(samples: 320).samples == Array(repeating: Float(1), count: 320))
        await source.stop()
    }
    @Test func silentStartupDoesNotPinAutoToAnArbitraryDevice() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .auto, devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        for _ in 0..<25 { _ = await source.render(samples: 320) }
        #expect(await source.activeDeviceUID == nil)
        first.push(0.4); second.push(0); try await waitForBuffers(source, count: 2)
        #expect(await source.render(samples: 320).samples.first == 0.4)
        #expect(await source.activeDeviceUID == "a")
        await source.stop()
    }
    @Test func slowOldNativeStartCannotReplaceLatestSelection() async throws {
        let gate = MeetingStartGate()
        let first = MeetingInput(gate: gate), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .device("a"), devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        let start = Task { try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1)) }
        let deadline = ContinuousClock.now + .seconds(30)
        while await !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
        await source.update(selection: .device("b"), devices: Self.devices)
        await gate.open()
        _ = try await start.value
        first.push(0.9); second.push(0.4)
        try await waitForBuffers(source, count: 1)
        #expect(await source.render(samples: 320).samples.first == 0.4)
        await source.stop()
    }
    @Test func realClockEmitsBothSidesOfLiveSwitchOnOriginalStream() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .device("a"), devices: Self.devices, makeSource: { $0.id == 1 ? first : second })
        let stream = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        let chunks = MicrophoneChunks()
        let reader = Task { for await chunk in stream { await chunks.add(chunk) }; await chunks.finish() }
        first.push(0.2, samples: 4096)
        let deadline = ContinuousClock.now + .seconds(30)
        while await !chunks.values.contains(where: { $0.samples.contains(0.2) }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await chunks.values.contains(where: { $0.samples.contains(0.2) }))
        await source.update(selection: .device("b"), devices: Self.devices)
        first.push(0.9); second.push(0.4, samples: 4096)
        while await !chunks.values.contains(where: { $0.samples.contains(0.4) }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await chunks.values.contains(where: { $0.samples.contains(0.4) }))
        #expect(await chunks.values.contains(where: { $0.samples.contains(0.9) }) == false)
        #expect(await chunks.finished == false)
        await source.stop(); await reader.value
        #expect(await chunks.finished)
    }

    @Test func sharedClockStartDiscardsEarlierInputsPreOriginBacklog() async throws {
        let gate = MeetingStartGate()
        let first = MeetingInput(), second = MeetingInput(gate: gate)
        let source = MeetingMicrophoneSource(selection: .all, devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        let start = Task { try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1)) }
        let deadline = ContinuousClock.now + .seconds(30)
        while await !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
        first.push(0.2, samples: 8000)
        try await waitForBuffers(source, count: 1)
        await gate.open()
        _ = try await start.value
        #expect(await source.bufferedInputCount == 0)
        #expect(await source.render(samples: 320).samples.first == 0)
        first.push(0.4); second.push(0.3); try await waitForBuffers(source, count: 2)
        #expect(abs((await source.render(samples: 320).samples.first ?? 0) - 0.7) < 0.0001)
        await source.stop()
    }

    @Test func autoPreservesQuietAudioAndSwitchesToALouderQuietInput() async throws {
        let first = MeetingInput(), second = MeetingInput()
        let source = MeetingMicrophoneSource(selection: .auto, devices: Self.devices, automaticTicks: false, makeSource: { $0.id == 1 ? first : second })
        _ = try await source.start(format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        first.push(0.0001); second.push(0)
        try await waitForBuffers(source, count: 2)
        #expect(await source.render(samples: 320).samples.first == 0.0001)
        for _ in 0..<60 {
            first.push(0.0001); second.push(0.001)
            try await waitForBuffers(source, count: 2)
            _ = await source.render(samples: 320)
        }
        #expect(await source.activeDeviceUID == "b")
        await source.stop()
    }

}
