import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoAudio

private struct StartFailed: Error {}

private actor StartGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var entered = false
    func wait() async throws {
        entered = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fail() { continuation?.resume(throwing: StartFailed()); continuation = nil }
}

/// A microphone the test drives; remembers whether it was asked for voice processing.
private final class FakeMic: ResumableAudioSource {
    let voiceProcessing: Bool
    let device: UInt32?
    private let failStart: Bool
    private let refuseDevice: Bool
    private let endsImmediately: Bool
    private let startDelay: Duration?
    private let startGate: StartGate?
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let stops = Mutex(0)
    private let resumeSink: AsyncStream<Void>.Continuation
    let resumptions: AsyncStream<Void>
    var stopCount: Int { stops.withLock { $0 } }
    var hasStarted: Bool { continuation.withLock { $0 != nil } }

    init(voiceProcessing: Bool, device: UInt32? = nil, failStart: Bool = false, refuseDevice: Bool = false, endsImmediately: Bool = false, startDelay: Duration? = nil, startGate: StartGate? = nil) {
        self.voiceProcessing = voiceProcessing
        self.device = device
        self.failStart = failStart
        self.refuseDevice = refuseDevice
        self.endsImmediately = endsImmediately
        self.startDelay = startDelay
        self.startGate = startGate
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self)
    }

    func push(_ level: Float, seconds: Double = 0.1) {
        let count = Int(16_000 * seconds)
        let chunk = AudioChunk(samples: Array(repeating: level, count: count), format: AudioFormatSpec(sampleRate: 16_000, channelCount: 1))
        continuation.withLock { _ = $0?.yield(chunk) }
    }
    func push(_ chunk: AudioChunk) { continuation.withLock { _ = $0?.yield(chunk) } }
    func resume() { resumeSink.yield() }
    func endUnexpectedly() { continuation.withLock { $0?.finish() } }

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        if let startDelay { try await Task.sleep(for: startDelay) }
        if let startGate { try await startGate.wait() }
        if failStart { throw StartFailed() }
        if refuseDevice, let device { throw MicSourceError.deviceNotSelected(device: device, status: -10851) }
        let (stream, cont) = AsyncStream<AudioChunk>.makeStream()
        continuation.withLock { $0 = cont }
        if endsImmediately { cont.finish() }
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
/// A mic on a device in `refused` cannot select it (as `MicSource` throws).
private final class Factory: Sendable {
    private let plan: Mutex<[(vp: Bool, fail: Bool)]>
    private let refused: Set<UInt32>
    private let immediateEnds: Mutex<Int>
    private let startDelay: Duration?
    let made = Mutex<[FakeMic]>([])
    init(_ plan: [(vp: Bool, fail: Bool)], refused: Set<UInt32> = [], immediateEnds: Int = 0, startDelay: Duration? = nil) {
        self.plan = Mutex(plan)
        self.refused = refused
        self.immediateEnds = Mutex(immediateEnds)
        self.startDelay = startDelay
    }
    func make(_ vp: Bool, _ device: UInt32? = nil) -> any AudioSource {
        let next = plan.withLock { $0.isEmpty ? (vp: vp, fail: false) : $0.removeFirst() }
        let refuse = device.map { refused.contains($0) } ?? false
        let end = immediateEnds.withLock { count in defer { count = max(0, count - 1) }; return count > 0 }
        let mic = FakeMic(voiceProcessing: vp, device: device, failStart: next.fail, refuseDevice: refuse, endsImmediately: end, startDelay: startDelay)
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
    func settled() async { await task.withLock { $0 }?.value }
    deinit { task.withLock { $0 }?.cancel() }
}

private let format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

private func eventually(timeout: Duration = .seconds(30), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
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
            voiceProcessing: true, guardian: MicSilenceGuard(window: 1, grace: 0), make: { factory.make($0) })
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

    /// The field bug: a plain meeting mic on an unused AirPods mic recorded nothing, and nobody was told.
    @Test func aPlainMicThatHearsOnlyANoiseFloorSaysSo() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(voiceProcessing: false, make: { factory.make($0) })
        let notices = Tally(source.notices)
        let stream = try await source.start(format: format)
        let (_, reader) = collect(stream)
        for chunk in MicSignals.chunks(MicSignals.deadAirPods()) { factory.mics[0].push(chunk) }
        #expect(await eventually { notices.values == ["Your mic hears nothing — check the input in System Settings → Sound"] })
        #expect(factory.mics.count == 1, "no other device to switch to")
        await source.stop()
        await reader.value
    }

    private let builtIn: UInt32 = 92
    private let airPods: UInt32 = 122

    /// The AirPods are the default input; the call app records from the built-in mic (or from `call`).
    private func devices(call: UInt32?) -> MicDevices {
        MicDevices(
            defaultInput: { 122 },
            name: { [92: "MacBook Pro Microphone", 122: "AirPods Pro"][$0] },
            callInput: { call })
    }

    @Test func aDeadMicNamesTheCallsDeviceAndSwitchesToIt() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, devices: devices(call: builtIn), makeMic: { factory.make($0, $1) })
        let notices = Tally(source.notices), resumptions = Tally(source.resumptions)
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        for chunk in MicSignals.chunks(MicSignals.deadAirPods()) { factory.mics[0].push(chunk) }

        #expect(await eventually { notices.values == ["Your mic (AirPods Pro) hears nothing — the call uses MacBook Pro Microphone"] })
        try #require(await eventually { factory.mics.count == 2 })
        #expect(factory.mics.map(\.device) == [nil, builtIn])
        #expect(await eventually { resumptions.values.count == 1 }, "the meeting is told to fill the gap")
        factory.mics[1].push(0.5)
        #expect(await eventually { got.values.last == 0.5 })
        await source.stop()
        await reader.value
    }

    @Test func aDeadMicOnTheCallsOwnDeviceIsOnlyReported() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, devices: devices(call: builtIn), makeMic: { factory.make($0, $1) })
        let notices = Tally(source.notices)
        _ = try await source.start(format: format)
        for chunk in MicSignals.chunks(MicSignals.deadAirPods()) { factory.mics[0].push(chunk) }
        #expect(await eventually {
            notices.values == ["Your mic (MacBook Pro Microphone) hears nothing — check the input in System Settings → Sound"]
        })
        #expect(factory.mics.count == 1)
        await source.stop()
    }

    @Test func followingTheCallAppMovesTheMicOnTheSameStream() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, devices: devices(call: nil), makeMic: { factory.make($0, $1) })
        let resumptions = Tally(source.resumptions)
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        factory.mics[0].push(0.1)

        await source.follow(device: builtIn) // the call started after the meeting
        try #require(factory.mics.map(\.device) == [nil, builtIn])
        #expect(factory.mics[0].stopCount == 1)
        #expect(await eventually { resumptions.values.count == 1 })
        factory.mics[1].push(0.2)
        #expect(await eventually { got.values == [0.1, 0.2] })

        await source.follow(device: builtIn) // already there
        #expect(factory.mics.count == 2)
        await source.stop()
        await reader.value
    }

    @Test func aFollowedDeviceIsUsedFromTheStart() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(voiceProcessing: true, device: builtIn, makeMic: { factory.make($0, $1) })
        _ = try await source.start(format: format)
        #expect(factory.mics.map(\.device) == [builtIn])
        #expect(factory.mics[0].voiceProcessing)
        await source.stop()
    }

    @Test func aRestartOfTheMicIsJudgedAgain() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, guardian: MicSilenceGuard(window: 1, grace: 0), make: { factory.make($0) })
        let notices = Tally(source.notices), resumptions = Tally(source.resumptions)
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        for _ in 0..<10 { factory.mics[0].push(0.3) } // working
        #expect(await eventually { got.values.count == 10 })
        factory.mics[0].resume() // the engine was rebuilt after a device change
        #expect(await eventually { resumptions.values.count == 1 })
        for _ in 0..<10 { factory.mics[0].push(0) } // and the new device hears nothing
        #expect(await eventually { notices.values == ["Your mic hears nothing — check the input in System Settings → Sound"] })
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

    /// The field bug: the meeting mic could not select the call's device and stayed on the dead default input,
    /// and nobody was told.
    @Test func aDeviceThatCannotBeSelectedIsReportedAndTheDefaultInputRecords() async throws {
        let factory = Factory([], refused: [builtIn])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, devices: devices(call: builtIn), makeMic: { factory.make($0, $1) })
        let notices = Tally(source.notices)
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)

        #expect(factory.mics.map(\.device) == [builtIn, nil])
        #expect(await eventually {
            notices.values == ["Couldn't record from MacBook Pro Microphone — recording from the default input instead"]
        })
        factory.mics[1].push(0.4)
        #expect(await eventually { got.values == [0.4] })
        await source.stop()
        await reader.value
    }

    @Test func anExplicitMicrophoneNeverFallsBackToTheDefault() async {
        let factory = Factory([], refused: [builtIn])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, devices: devices(call: nil), strictDevice: true,
            makeMic: { factory.make($0, $1) })
        await #expect(throws: MicSourceError.self) { _ = try await source.start(format: format) }
        #expect(factory.mics.map(\.device) == [builtIn])
    }

    @Test func aRefusedDeviceIsNotRetriedOnEveryFollow() async throws {
        let factory = Factory([], refused: [builtIn])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, devices: devices(call: nil), makeMic: { factory.make($0, $1) })
        let notices = Tally(source.notices)
        _ = try await source.start(format: format)

        await source.follow(device: builtIn) // refused: back on the default
        #expect(factory.mics.map(\.device) == [nil, builtIn, nil])
        await source.follow(device: builtIn) // the call app is polled again: same device, no new attempt
        await source.follow(device: builtIn)
        #expect(factory.mics.count == 3)
        #expect(await eventually { notices.values.count >= 1 })
        await source.stop() // closes notices after the source's work has joined
        await notices.settled()
        #expect(notices.values.count == 1, "one notice, not one per poll")
    }

    @Test func anUnexpectedEndRecoversTheSameExplicitInputWithoutVoiceProcessing() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: true, device: builtIn, strictDevice: true, clock: { 0 }, makeMic: { factory.make($0, $1) })
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        factory.mics[0].endUnexpectedly()
        try #require(await eventually { factory.mics.count == 2 })
        #expect(factory.mics.map(\.device) == [builtIn, builtIn])
        #expect(factory.mics.map(\.voiceProcessing) == [true, false])
        factory.mics[1].push(0.4)
        #expect(await eventually { got.values == [0.4] })
        await source.stop()
        await reader.value
    }

    @Test func immediatelyEndingSourcesExhaustRecoveryAndEndThePublicStream() async throws {
        let factory = Factory([], immediateEnds: 10, startDelay: .milliseconds(1200))
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, strictDevice: true, clock: { 0 }, makeMic: { factory.make($0, $1) })
        let notices = Tally(source.notices)
        let stream = try await source.start(format: format)
        let ended = Got()
        let reader = Task { for await _ in stream {}; ended.append(1) }
        #expect(await eventually { ended.values == [1] })
        #expect(factory.mics.map(\.device) == [builtIn, builtIn, builtIn])
        #expect(await eventually { notices.values.contains(VoiceProcessingFallbackMic.restartFailedNotice) })
        await source.stop()
        await reader.value
    }

    @Test func watchdogRecoveryDoesNotInheritItsCancelledWatchdogTask() async throws {
        let made = Mutex<[FakeMic]>([])
        let clock = Mutex(0.0)
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, strictDevice: true,
            clock: { clock.withLock { $0 } }, makeMic: { vp, device in
                // Recovery must tolerate a cancellable start slower than the old assertion deadline.
                let mic = FakeMic(voiceProcessing: vp, device: device, startDelay: .milliseconds(1200))
                made.withLock { $0.append(mic) }
                return mic
            })
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        clock.withLock { $0 = 4 } // Past the production three-second stall threshold, then hold time still.
        try #require(await eventually { made.withLock { $0.count == 2 && $0[1].hasStarted } })
        made.withLock { $0[1] }.push(0.4)
        #expect(await eventually { got.values == [0.4] })
        await source.stop()
        await reader.value
    }

    @Test func anObsoleteSwitchFailureCannotStopANewerStart() async throws {
        let gate = StartGate()
        let made = Mutex<[FakeMic]>([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, strictDevice: true, clock: { 0 },
            makeMic: { vp, device in
                made.withLock { mics in
                    let mic = FakeMic(voiceProcessing: vp, device: device, startGate: mics.count == 1 ? gate : nil)
                    mics.append(mic)
                    return mic
                }
            })
        _ = try await source.start(format: format)
        let switching = Task { await source.follow(device: airPods) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        await gate.fail()
        await switching.value
        made.withLock { $0[2] }.push(0.5)
        #expect(await eventually { got.values == [0.5] })
        await source.stop()
        await reader.value
    }

    @Test func aStalledOpenStreamRecoversWithoutUsingSilenceAsAFailure() async throws {
        let factory = Factory([], startDelay: .milliseconds(1200))
        let clock = Mutex(0.0)
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, strictDevice: true,
            clock: { clock.withLock { $0 } }, makeMic: { factory.make($0, $1) })
        _ = try await source.start(format: format)
        clock.withLock { $0 = 4 }
        #expect(await eventually { factory.mics.count == 2 && factory.mics[1].hasStarted })
        #expect(factory.mics.map(\.device) == [builtIn, builtIn])
        await source.stop()
    }

    @Test func liveSilentCallbacksNeverTriggerTheStallWatchdog() async throws {
        let factory = Factory([])
        let clock = Mutex(0.0)
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, strictDevice: true, stallTimeout: 0.15,
            clock: { clock.withLock { $0 } }, makeMic: { factory.make($0, $1) })
        let stream = try await source.start(format: format)
        let (got, reader) = collect(stream)
        for count in 1...20 {
            factory.mics[0].push(0)
            try #require(await eventually { got.values.count == count })
            clock.withLock { $0 += 0.05 }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(factory.mics.count == 1)
        await source.stop()
        await reader.value
    }

    @Test func aFailedRecoveryEndsThePublicStreamWithANotice() async throws {
        let factory = Factory([(vp: false, fail: false), (vp: false, fail: true)], startDelay: .milliseconds(1200))
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: builtIn, strictDevice: true, clock: { 0 }, makeMic: { factory.make($0, $1) })
        let notices = Tally(source.notices)
        let stream = try await source.start(format: format)
        let ended = Got()
        let reader = Task { for await _ in stream {}; ended.append(1) }
        factory.mics[0].endUnexpectedly()
        #expect(await eventually { ended.values == [1] })
        #expect(await eventually { notices.values.contains(VoiceProcessingFallbackMic.restartFailedNotice) })
        #expect(factory.mics.map(\.device) == [builtIn, builtIn])
        await source.stop()
        await reader.value
    }

    @Test func anIntentionalSwitchDoesNotStartStaleRecovery() async throws {
        let factory = Factory([])
        let source = VoiceProcessingFallbackMic(
            voiceProcessing: false, device: airPods, clock: { 0 }, makeMic: { factory.make($0, $1) })
        _ = try await source.start(format: format)
        await source.follow(device: builtIn) // joins the old microphone's pump before replacing it
        #expect(factory.mics[0].stopCount == 1 && factory.mics[1].hasStarted)
        #expect(factory.mics.map(\.device) == [airPods, builtIn])
        await source.stop() // joins the replacement pump as well
        #expect(factory.mics[1].stopCount == 1)
        #expect(factory.mics.count == 2)
    }

    @Test func aFailingStartWithoutVoiceProcessingStillThrows() async {
        let factory = Factory([(vp: false, fail: true)])
        let source = VoiceProcessingFallbackMic(voiceProcessing: false, make: { factory.make($0) })
        await #expect(throws: StartFailed.self) { _ = try await source.start(format: format) }
    }
}
