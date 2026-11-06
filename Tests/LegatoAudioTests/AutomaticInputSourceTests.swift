import Foundation
import LegatoCore
import Synchronization
import Testing
@testable import LegatoAudio

private let autoFormat = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
private final class InputProbe: Sendable {
    struct State { var opened: Set<String> = []; var maximum = 0; var attempts: [String] = [] }
    let state = Mutex(State())
    func open(_ id: String) { state.withLock { $0.opened.insert(id); $0.maximum = max($0.maximum, $0.opened.count); $0.attempts.append(id) } }
    func close(_ id: String) { state.withLock { _ = $0.opened.remove(id) } }
}
private final class InputInventory: Sendable {
    let state: Mutex<[AudioInputCandidate]>
    init(_ inputs: [AudioInputCandidate]) { state = Mutex(inputs) }
}
private final class MadeInputs: Sendable { let state = Mutex<[FakeAutomaticMic]>([]) }
private final class FakeAutomaticMic: AudioSource {
    /// `missing` stays open and silent (only the no-PCM timeout ends it); `closes` ends its stream without PCM.
    enum Behavior: Sendable { case quiet, speech, clipped, missing, closes, invalid, throwsAtStart }
    struct State { var sink: AsyncStream<AudioChunk>.Continuation?; var task: Task<Void, Never>? }
    let state = Mutex(State())
    let id: String, behavior: Behavior, probe: InputProbe
    init(id: String, behavior: Behavior, probe: InputProbe) { self.id = id; self.behavior = behavior; self.probe = probe }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        probe.open(id)
        if behavior == .throwsAtStart { throw MicSourceError.invalidInputFormat }
        let (stream, sink) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let behavior = behavior
        if behavior == .closes { sink.finish() }
        let task = Task {
            while !Task.isCancelled {
                if behavior != .missing {
                    let value: Float = behavior == .invalid ? .nan : (behavior == .quiet ? 0 : (behavior == .clipped ? 1 : 0.2))
                    sink.yield(.init(samples: Array(repeating: value, count: behavior == .clipped ? 1_600 : 160), format: format))
                }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
        }
        state.withLock { $0.sink = sink; $0.task = task }
        return stream
    }
    func route() async throws -> AsyncStream<AudioChunk> { throw MicSourceError.notArmed }
    func detach() async {}
    func stop() async {
        let taken = state.withLock { s in defer { s = State() }; return s }
        taken.task?.cancel(); taken.sink?.finish(); probe.close(id)
    }
}
private func autoCandidate(_ id: String, _ kind: AudioInputCandidate.Kind, alive: Bool = true, channels: Int = 1, rate: Double = 48_000) -> AudioInputCandidate {
    .init(id: id, name: id, kind: kind, available: alive, channels: channels, sampleRate: rate)
}
private func autoHardware(_ candidates: InputInventory, probe: InputProbe,
                          behavior: @escaping @Sendable (String) -> FakeAutomaticMic.Behavior = { _ in .quiet },
                          made: MadeInputs? = nil) -> AutomaticInputHardware {
    .init(candidates: { candidates.state.withLock { $0 } }, make: { input in
        let mic = FakeAutomaticMic(id: input.id, behavior: behavior(input.id), probe: probe)
        made?.state.withLock { $0.append(mic) }; return mic
    }, isCurrent: { input in candidates.state.withLock { $0.contains(where: { $0.id == input.id && $0.isUsable }) } })
}
/// Upper bound for "first PCM" in tests: only a silent input ever reaches it, so scheduler stalls cannot.
private let neverReached = Duration.seconds(30)
private let tick = Duration.milliseconds(20)
private func waitForAutomaticInput(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    Issue.record("Automatic input did not reach the expected state")
}

@Test func automaticInputPrefersBuiltInAndRejectsAggregatesVirtualAndInvalidRoutes() {
    let inputs = [autoCandidate("AirPods", .bluetooth), autoCandidate("ALL", .aggregate, channels: 3),
        autoCandidate("Teams", .virtual), autoCandidate("dead", .wired, alive: false),
        autoCandidate("no-input", .wired, channels: 0), autoCandidate("bad-rate", .wired, rate: 0),
        autoCandidate("Built-in", .builtIn), autoCandidate("USB", .wired)]
    #expect(AudioInputCandidate.ordered(inputs).map(\.id) == ["Built-in", "USB", "AirPods"])
}

@Test func automaticInputAcceptsValidSilentBuffersWithoutProbingOtherMicrophones() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("AirPods", .bluetooth), autoCandidate("Built-in", .builtIn)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe), timeout: neverReached, healthInterval: tick)
    _ = try await source.start(format: autoFormat)
    try await Task.sleep(for: .milliseconds(160))
    #expect(source.diagnostics.selected?.id == "Built-in")
    #expect(source.diagnostics.buffers > 0 && source.diagnostics.rms == 0)
    #expect(source.diagnostics.convertedSampleRate == 16_000 && source.diagnostics.convertedChannels == 1)
    #expect(probe.state.withLock { $0.attempts } == ["Built-in"])
    await source.stop()
    #expect(probe.state.withLock { $0.opened.isEmpty })
}

@Test(arguments: [FakeAutomaticMic.Behavior.closes, .invalid, .throwsAtStart])
private func automaticInputFallsBackAfterStrongFailureWithoutOpeningTwoDevices(_ failure: FakeAutomaticMic.Behavior) async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("broken", .builtIn), autoCandidate("USB", .wired), autoCandidate("AirPods", .bluetooth)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, behavior: { $0 == "broken" ? failure : .speech }), timeout: neverReached, healthInterval: tick)
    _ = try await source.start(format: autoFormat)
    #expect(source.diagnostics.selected?.id == "USB")
    #expect(source.diagnostics.rejectedInputs["broken"] != nil)
    #expect(probe.state.withLock { $0.maximum } == 1)
    #expect(probe.state.withLock { $0.attempts } == ["broken", "USB"])
    await source.stop()
}

@Test func automaticInputThatNeverDeliversPCMIsRejectedAfterTheTimeout() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("mute", .builtIn)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, behavior: { _ in .missing }), timeout: .milliseconds(50))
    await #expect(throws: AutomaticInputError.self) { _ = try await source.start(format: autoFormat) }
    #expect(source.diagnostics.rejectedInputs["mute"] != nil)
    #expect(probe.state.withLock { $0.opened.isEmpty && $0.attempts == ["mute"] })
}

@Test func automaticInputDisconnectRecoversOnTheSameStream() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn), autoCandidate("USB", .wired)])
    let made = MadeInputs()
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, made: made), timeout: neverReached, healthInterval: tick)
    let stream = try await source.start(format: autoFormat)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next()?.format == autoFormat)
    inputs.state.withLock { $0.removeAll { $0.id == "Built-in" } }
    let old = try #require(made.state.withLock { $0.first })
    await old.stop()
    try await waitForAutomaticInput { source.diagnostics.selected?.id == "USB" && source.diagnostics.state == "capturing" }
    #expect(await iterator.next()?.format == autoFormat)
    #expect(source.diagnostics.recoveries == 1)
    #expect(probe.state.withLock { $0.maximum } == 1)
    await source.stop()
}

@Test func automaticInputRepairsADeadMicrophoneDuringADetachedLease() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn), autoCandidate("USB", .wired)])
    let made = MadeInputs()
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, made: made), timeout: neverReached, healthInterval: tick)
    _ = try await source.start(format: autoFormat)
    await source.detach()
    inputs.state.withLock { $0.removeAll { $0.id == "Built-in" } }
    await made.state.withLock { $0[0] }.stop()
    try await waitForAutomaticInput { source.diagnostics.selected?.id == "USB" && source.diagnostics.captureHealthy }
    #expect(probe.state.withLock { $0.attempts } == ["Built-in", "USB"])
    _ = try await source.route()
    #expect(source.diagnostics.selected?.id == "USB")
    await source.stop()
}

@Test func automaticInputStopWinsDuringAStartThatHasNoPCM() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, behavior: { _ in .missing }), timeout: neverReached, healthInterval: tick)
    let start = Task { try await source.start(format: autoFormat) }
    try await waitForAutomaticInput { probe.state.withLock { !$0.opened.isEmpty } }
    await source.stop()
    do { _ = try await start.value; Issue.record("Stopped start succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(probe.state.withLock { $0.opened.isEmpty })
    #expect(source.diagnostics.state == "idle")
}

@Test func automaticInputPreflightKeepsTheFirstQuarterSecondForTheConsumer() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, behavior: { _ in .speech }),
        timeout: neverReached, preflight: .milliseconds(250), healthInterval: tick)
    let stream = try await source.start(format: autoFormat)
    #expect(source.diagnostics.frames >= 4_000)
    #expect(source.diagnostics.calibration == "ready-signal")
    var iterator = stream.makeAsyncIterator()
    var frames = 0
    for _ in 0..<25 { frames += try #require(await iterator.next()).samples.count }
    #expect(frames == 4_000)
    await source.stop()
}

@Test func automaticInputMakesOnlyOneMeasuredLowerClippingTrial() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn), autoCandidate("USB", .wired)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe,
        behavior: { $0 == "Built-in" ? .clipped : .speech }), timeout: neverReached, healthInterval: tick)
    _ = try await source.start(format: autoFormat)
    try await waitForAutomaticInput { source.diagnostics.qualityComparison == "lower distortion accepted" }
    #expect(source.diagnostics.selected?.id == "USB")
    #expect(source.diagnostics.qualityComparison == "lower distortion accepted")
    #expect(probe.state.withLock { $0.maximum } == 1)
    #expect(probe.state.withLock { $0.attempts } == ["Built-in", "USB"])
    await source.stop()
}

@Test func inputSignalQualityDoesNotConfuseSilenceAndDistortion() {
    var meter = InputQualityMeter()
    let quiet = meter.observe(.init(samples: Array(repeating: 0, count: 160), format: autoFormat))
    #expect(quiet.state == "quiet" && quiet.clippedFraction == 0)
    let clipped = meter.observe(.init(samples: Array(repeating: 1, count: 160), format: autoFormat))
    #expect(clipped.state == "clipping" && clipped.clippedFraction == 0.5)
}

@Test func automaticInputRecoveryRetriesTheSameMicAfterTransientStartFailure() async throws {
    let probe = InputProbe(), inventory = InputInventory([autoCandidate("Built-in", .builtIn)])
    let made = MadeInputs()
    let count = Mutex(0)
    let hardware = AutomaticInputHardware(candidates: { inventory.state.withLock { $0 } }, make: { candidate in
        let attempt = count.withLock { value in value += 1; return value }
        let mic = FakeAutomaticMic(id: candidate.id, behavior: attempt == 2 ? .throwsAtStart : .speech, probe: probe)
        made.state.withLock { $0.append(mic) }
        return mic
    }, isCurrent: { _ in true })
    let source = AutomaticInputSource(hardware: hardware, timeout: neverReached, healthInterval: tick)
    let stream = try await source.start(format: autoFormat)
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    await made.state.withLock { $0[0] }.stop()
    try await waitForAutomaticInput { source.diagnostics.captureHealthy && source.diagnostics.recoveries == 2 }
    #expect(await iterator.next() != nil)
    #expect(probe.state.withLock { $0.attempts.count } == 3)
    await source.stop()
}

@Test func automaticInputStopsRepairingAfterItsBoundedBudget() async throws {
    let probe = InputProbe(), inventory = InputInventory([autoCandidate("Built-in", .builtIn)])
    let made = MadeInputs()
    let count = Mutex(0)
    let hardware = AutomaticInputHardware(candidates: { inventory.state.withLock { $0 } }, make: { candidate in
        let first = count.withLock { value in value += 1; return value == 1 }
        let mic = FakeAutomaticMic(id: candidate.id, behavior: first ? .speech : .throwsAtStart, probe: probe)
        made.state.withLock { $0.append(mic) }
        return mic
    }, isCurrent: { _ in true })
    let source = AutomaticInputSource(hardware: hardware, timeout: neverReached, healthInterval: tick)
    _ = try await source.start(format: autoFormat)
    await source.detach()
    await made.state.withLock { $0[0] }.stop()
    try await waitForAutomaticInput { source.diagnostics.state == "failed" }
    #expect(source.diagnostics.recoveries == 3)
    #expect(!source.diagnostics.captureHealthy)
    #expect(probe.state.withLock { $0.attempts.count == 4 && $0.opened.isEmpty })
    await source.stop()
}

@Test func automaticInputCombinedFailureDowngradesOnceAndCapturesFromBuiltIn() async throws {
    let probe = InputProbe(), inventory = InputInventory([autoCandidate("combined", .combined, channels: 2)])
    let fallbacks = Mutex(0)
    var hardware = autoHardware(inventory, probe: probe, behavior: { $0 == "combined" ? .throwsAtStart : .speech })
    hardware.fallbackFromCombined = { _ in
        fallbacks.withLock { $0 += 1 }
        inventory.state.withLock { $0 = [autoCandidate("Built-in", .builtIn)] }
    }
    let source = AutomaticInputSource(hardware: hardware, timeout: neverReached, healthInterval: tick)
    let stream = try await source.start(format: autoFormat)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    #expect(source.diagnostics.selected?.id == "Built-in")
    // Readiness is time-sensitive: wait for fresh PCM rather than assuming the
    // test executor resumes within two seconds of the first buffered chunk.
    var captureHealthy = false
    try await waitForAutomaticInput {
        captureHealthy = source.diagnostics.captureHealthy
        return captureHealthy
    }
    #expect(captureHealthy)
    #expect(fallbacks.withLock { $0 } == 1)
    #expect(probe.state.withLock { $0.attempts == ["combined", "Built-in"] && $0.maximum == 1 })
    await source.stop()
}

@Test func automaticInputCombinedFallbackRejectionPreservesNativeFailure() async throws {
    let probe = InputProbe(), inventory = InputInventory([autoCandidate("combined", .combined, channels: 2)])
    let fallbacks = Mutex(0)
    var hardware = autoHardware(inventory, probe: probe, behavior: { _ in .throwsAtStart })
    hardware.fallbackFromCombined = { _ in
        fallbacks.withLock { $0 += 1 }
        throw NSError(domain: "TestAudioSession", code: 561017449)
    }
    let source = AutomaticInputSource(hardware: hardware, timeout: neverReached, healthInterval: tick)
    do {
        _ = try await source.start(format: autoFormat)
        Issue.record("Rejected fallback succeeded")
    } catch let error as CombinedInputFallbackFailure {
        #expect((error.cause as NSError).domain == "TestAudioSession")
        #expect((error.cause as NSError).code == 561017449)
    }
    #expect(fallbacks.withLock { $0 } == 1)
    #expect(source.diagnostics.error?.contains("561017449") == true)
    #expect(!source.diagnostics.captureHealthy)
    await source.stop()
}

@Test func automaticInputCombinedRecoveryDowngradesOnTheExistingStream() async throws {
    let probe = InputProbe(), inventory = InputInventory([autoCandidate("combined", .combined, channels: 2)])
    let made = MadeInputs(), count = Mutex(0), fallbacks = Mutex(0)
    let hardware = AutomaticInputHardware(candidates: { inventory.state.withLock { $0 } }, make: { candidate in
        let attempt = count.withLock { value in value += 1; return value }
        let mic = FakeAutomaticMic(id: candidate.id,
            behavior: attempt == 2 ? .throwsAtStart : .speech, probe: probe)
        made.state.withLock { $0.append(mic) }
        return mic
    }, isCurrent: { _ in true }, fallbackFromCombined: { _ in
        fallbacks.withLock { $0 += 1 }
        inventory.state.withLock { $0 = [autoCandidate("Built-in", .builtIn)] }
    })
    let source = AutomaticInputSource(hardware: hardware, timeout: neverReached, healthInterval: tick)
    let stream = try await source.start(format: autoFormat)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    await made.state.withLock { $0[0] }.stop()
    try await waitForAutomaticInput { source.diagnostics.captureHealthy && source.diagnostics.selected?.id == "Built-in" }
    #expect(await iterator.next() != nil)
    #expect(fallbacks.withLock { $0 } == 1)
    #expect(source.diagnostics.recoveries == 1)
    #expect(probe.state.withLock { $0.attempts == ["combined", "combined", "Built-in"] && $0.maximum == 1 })
    await source.stop()
}

@Test func combinedFallbackPreservesNativeCauseWithoutShowingTechnicalErrors() throws {
    let original = NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)
    let failure = CombinedInputFallbackFailure(cause: original)
    let bridged = failure as NSError
    let underlying = try #require(bridged.userInfo[NSUnderlyingErrorKey] as? NSError)
    #expect(underlying.domain == original.domain && underlying.code == original.code)
    #expect(failure.localizedDescription == "Open Legato to ready the microphone again.")
}
