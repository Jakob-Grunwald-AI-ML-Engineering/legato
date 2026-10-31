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
    enum Behavior: Sendable { case quiet, speech, clipped, missing, invalid, throwsAtStart }
    struct State { var sink: AsyncStream<AudioChunk>.Continuation?; var task: Task<Void, Never>? }
    let state = Mutex(State())
    let id: String, behavior: Behavior, probe: InputProbe
    init(id: String, behavior: Behavior, probe: InputProbe) { self.id = id; self.behavior = behavior; self.probe = probe }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        probe.open(id)
        if behavior == .throwsAtStart { throw MicSourceError.invalidInputFormat }
        let (stream, sink) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let behavior = behavior
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
private func waitForAutomaticInput(_ condition: () async -> Bool) async throws {
    for _ in 0..<100 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
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
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe), timeout: .milliseconds(60))
    _ = try await source.start(format: autoFormat)
    try await Task.sleep(for: .milliseconds(160))
    #expect(source.diagnostics.selected?.id == "Built-in")
    #expect(source.diagnostics.buffers > 0 && source.diagnostics.rms == 0)
    #expect(source.diagnostics.convertedSampleRate == 16_000 && source.diagnostics.convertedChannels == 1)
    #expect(probe.state.withLock { $0.attempts } == ["Built-in"])
    await source.stop()
    #expect(probe.state.withLock { $0.opened.isEmpty })
}

@Test(arguments: [FakeAutomaticMic.Behavior.missing, .invalid, .throwsAtStart])
private func automaticInputFallsBackAfterStrongFailureWithoutOpeningTwoDevices(_ failure: FakeAutomaticMic.Behavior) async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("broken", .builtIn), autoCandidate("USB", .wired), autoCandidate("AirPods", .bluetooth)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, behavior: { $0 == "broken" ? failure : .speech }), timeout: .milliseconds(50))
    _ = try await source.start(format: autoFormat)
    #expect(source.diagnostics.selected?.id == "USB")
    #expect(source.diagnostics.rejectedInputs["broken"] != nil)
    #expect(probe.state.withLock { $0.maximum } == 1)
    #expect(probe.state.withLock { $0.attempts } == ["broken", "USB"])
    await source.stop()
}

@Test func automaticInputDisconnectRecoversOnTheSameStream() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn), autoCandidate("USB", .wired)])
    let made = MadeInputs()
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, made: made), timeout: .milliseconds(60))
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

@Test func automaticInputDoesNotProbeOtherDevicesDuringADetachedLease() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn), autoCandidate("USB", .wired)])
    let made = MadeInputs()
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, made: made), timeout: .milliseconds(50))
    _ = try await source.start(format: autoFormat)
    await source.detach()
    inputs.state.withLock { $0.removeAll { $0.id == "Built-in" } }
    await made.state.withLock { $0[0] }.stop()
    try await Task.sleep(for: .milliseconds(120))
    #expect(probe.state.withLock { $0.attempts } == ["Built-in"])
    _ = try await source.route()
    #expect(source.diagnostics.selected?.id == "USB")
    await source.stop()
}

@Test func automaticInputStopWinsDuringAStartThatHasNoPCM() async throws {
    let probe = InputProbe(), inputs = InputInventory([autoCandidate("Built-in", .builtIn)])
    let source = AutomaticInputSource(hardware: autoHardware(inputs, probe: probe, behavior: { _ in .missing }), timeout: .seconds(1))
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
        timeout: .seconds(1), preflight: .milliseconds(250))
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
        behavior: { $0 == "Built-in" ? .clipped : .speech }), timeout: .milliseconds(100))
    _ = try await source.start(format: autoFormat)
    for _ in 0..<70 {
        if source.diagnostics.qualityComparison == "lower distortion accepted" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
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
