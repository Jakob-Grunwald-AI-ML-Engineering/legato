import Foundation
import LegatoCore

public enum MeetingMicrophoneSelection: Sendable, Hashable {
    case auto, all, device(String)
}

public struct MeetingMicrophoneDevice: Sendable, Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public init(id: UInt32, uid: String, name: String) {
        self.id = id; self.uid = uid; self.name = name
    }
}

/// One clock-driven microphone track. Physical inputs can change without ending the meeting's stream.
/// The caller supplies fixed-device sources; each must recover only on its assigned device.
public actor MeetingMicrophoneSource: ResumableAudioSource {
    public nonisolated let resumptions: AsyncStream<Void>
    private let resumeSink: AsyncStream<Void>.Continuation
    public nonisolated let notices: AsyncStream<String>
    private let noticeSink: AsyncStream<String>.Continuation
    private var selection: MeetingMicrophoneSelection
    private var devices: [MeetingMicrophoneDevice]
    private let makeSource: @Sendable (MeetingMicrophoneDevice) -> any AudioSource
    private let automaticTicks: Bool
    private struct Input {
        let token: UUID
        let device: MeetingMicrophoneDevice
        let source: any AudioSource
        var pump: Task<Void, Never>?
        var relay: Task<Void, Never>?
        var samples: [Float] = []
        var level: Float = 0
        var ended = false
    }
    private var inputs: [String: Input] = [:]
    private var output: AsyncStream<AudioChunk>.Continuation?
    private var ticker: Task<Void, Never>?
    private var running = false
    private var lifecycle = 0
    private var selectedUID: String?
    private var challenger: String?
    private var challengerSeconds = 0.0
    private var dwellSeconds = 0.0
    private var format = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
    private var lastTick = 0.0
    private var fractionalFrames = 0.0

    public init(selection: MeetingMicrophoneSelection, devices: [MeetingMicrophoneDevice], makeSource: @escaping @Sendable (MeetingMicrophoneDevice) -> any AudioSource) {
        self.selection = selection; self.devices = devices; self.makeSource = makeSource
        automaticTicks = true
        (notices, noticeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        (resumptions, resumeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // A manual render clock keeps timeline, switching and hysteresis tests deterministic.
    init(selection: MeetingMicrophoneSelection, devices: [MeetingMicrophoneDevice], automaticTicks: Bool, makeSource: @escaping @Sendable (MeetingMicrophoneDevice) -> any AudioSource) {
        self.selection = selection; self.devices = devices; self.makeSource = makeSource
        self.automaticTicks = automaticTicks
        (notices, noticeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        (resumptions, resumeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func update(selection: MeetingMicrophoneSelection, devices: [MeetingMicrophoneDevice]) async {
        self.selection = selection; self.devices = devices
        if running { await reconcile() }
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        guard format.channelCount == 1, format.sampleRate.isFinite, format.sampleRate >= 8_000, format.sampleRate <= 192_000 else { throw MeetingMicrophoneError.unsupportedFormat }
        lifecycle += 1
        let run = lifecycle
        await stopCurrent()
        guard lifecycle == run else { throw CancellationError() }
        running = true
        self.format = format
        let stream = newOutput()
        await reconcile()
        guard running, lifecycle == run else { return stream }
        // Child engines start sequentially. Nothing captured before this shared origin belongs
        // on the meeting timeline, including an earlier engine's queued half-second of speech.
        for uid in inputs.keys { inputs[uid]?.samples.removeAll(); inputs[uid]?.level = 0 }
        lastTick = ProcessInfo.processInfo.systemUptime
        fractionalFrames = 0
        if automaticTicks {
            ticker = Task { [weak self] in
                let clock = ContinuousClock()
                var next = clock.now
                while !Task.isCancelled {
                    next += .milliseconds(20)
                    do { try await clock.sleep(until: next) } catch { return }
                    guard let self else { return }
                    await self.tick(run: run)
                    // A suspended application must not enqueue an unbounded catch-up burst.
                    if next < clock.now - .milliseconds(100) { next = clock.now }
                }
            }
        }
        return stream
    }

    public func route() async throws -> AsyncStream<AudioChunk> { newOutput() }
    public func detach() async { output?.finish(); output = nil }
    public func stop() async {
        lifecycle += 1
        await stopCurrent()
    }

    private func stopCurrent() async {
        running = false
        ticker?.cancel(); ticker = nil
        output?.finish(); output = nil
        let previous = inputs.values
        inputs.removeAll()
        selectedUID = nil; challenger = nil; challengerSeconds = 0; dwellSeconds = 0
        for input in previous {
            input.pump?.cancel(); input.relay?.cancel()
            await input.source.stop()
        }
    }

    private func newOutput() -> AsyncStream<AudioChunk> {
        output?.finish()
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(250))
        output = continuation
        return stream
    }

    private func desiredDevices() -> [MeetingMicrophoneDevice] {
        var seen: Set<String> = []
        return devices.filter { device in
            guard seen.insert(device.uid).inserted else { return false }
            if case .device(let uid) = selection { return uid == device.uid }
            return true
        }
    }

    private func reconcile() async {
        let run = lifecycle
        let wanted = desiredDevices()
        let wantedByUID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.uid, $0) })
        let removed = inputs.filter { wantedByUID[$0.key] != $0.value.device || $0.value.ended }
        for (uid, input) in removed {
            inputs.removeValue(forKey: uid)
            input.pump?.cancel(); input.relay?.cancel()
        }
        for (_, input) in removed { await input.source.stop() }
        guard running, lifecycle == run else { return }
        // Re-evaluate after every await: a newer UI selection may already have superseded this one.
        for device in desiredDevices() {
            guard running, lifecycle == run else { return }
            guard desiredDevices().contains(device), inputs[device.uid] == nil else { continue }
            let token = UUID()
            let source = makeSource(device)
            inputs[device.uid] = Input(token: token, device: device, source: source)
            do {
                let stream = try await source.start(format: format)
                guard running, lifecycle == run, inputs[device.uid]?.token == token else {
                    await source.stop(); continue
                }
                inputs[device.uid]?.pump = Task { [weak self] in
                    for await chunk in stream {
                        guard !Task.isCancelled else { return }
                        await self?.receive(chunk, uid: device.uid, token: token)
                    }
                    await self?.ended(uid: device.uid, token: token)
                }
                if let source = source as? VoiceProcessingFallbackMic {
                    inputs[device.uid]?.relay = Task { [weak self] in
                        for await notice in source.notices {
                            guard !Task.isCancelled else { return }
                            await self?.relay(notice, uid: device.uid, token: token)
                        }
                    }
                }
            } catch {
                let current = inputs[device.uid]?.token == token
                if current {
                    inputs.removeValue(forKey: device.uid)
                    noticeSink.yield("Couldn't record from \(device.name): \(error.localizedDescription). Meeting audio continues.")
                }
                await source.stop()
            }
        }
        if inputs.isEmpty { noticeSink.yield("No selected microphone is available. Meeting audio continues.") }
    }

    private func relay(_ notice: String, uid: String, token: UUID) {
        guard inputs[uid]?.token == token else { return }
        noticeSink.yield(notice)
    }

    private func ended(uid: String, token: UUID) {
        guard let input = inputs[uid], input.token == token else { return }
        // A hardware refresh retries an ended input; clock ticks never trigger retry loops.
        inputs[uid]?.ended = true
        inputs[uid]?.samples.removeAll()
        inputs[uid]?.level = 0
        noticeSink.yield("\(input.device.name) stopped sending audio. Meeting audio continues.")
    }

    private func receive(_ chunk: AudioChunk, uid: String, token: UUID) {
        guard inputs[uid]?.token == token, chunk.format == format else { return }
        // A full second accommodates normal large driver buffers while bounding a stalled producer.
        let limit = Int(format.sampleRate)
        let finite = chunk.samples.map { $0.isFinite ? $0 : 0 }
        inputs[uid]?.samples.append(contentsOf: finite.suffix(limit))
        if let count = inputs[uid]?.samples.count, count > limit { inputs[uid]?.samples.removeFirst(count - limit) }
    }

    var bufferedInputCount: Int { inputs.values.filter { !$0.samples.isEmpty }.count }
    public var activeDeviceUID: String? { selectedUID }

    private func tick(run: Int) {
        guard running, lifecycle == run else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - lastTick)
        lastTick = now
        // A long suspension is placed by the downstream clock instead of allocating minutes of PCM.
        if elapsed > 2 {
            for uid in inputs.keys { inputs[uid]?.samples.removeAll(); inputs[uid]?.level = 0 }
            resumeSink.yield(())
            fractionalFrames = 0
            output?.yield(render(samples: Int(format.sampleRate * 0.02)))
            return
        }
        let frames = elapsed * format.sampleRate + fractionalFrames
        let count = Int(frames)
        fractionalFrames = frames - Double(count)
        if count > 0 { output?.yield(render(samples: count)) }
    }

    func render(samples count: Int) -> AudioChunk {
        let seconds = Double(count) / format.sampleRate
        var blocks: [String: [Float]] = [:]
        for uid in inputs.keys.sorted() {
            guard var input = inputs[uid] else { continue }
            let available = min(count, input.samples.count)
            var block = Array(input.samples.prefix(available))
            input.samples.removeFirst(available)
            block.append(contentsOf: repeatElement(Float.zero, count: count - available))
            let rms = sqrt(block.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(1, count)))
            input.level = input.level * 0.8 + rms * 0.2
            inputs[uid] = input; blocks[uid] = block
        }
        var included = Array(blocks.keys)
        switch selection {
        case .all: break
        case .device(let uid): selectedUID = uid; included = [uid]
        case .auto:
            let strongest = inputs.keys.sorted().max { (inputs[$0]?.level ?? 0) < (inputs[$1]?.level ?? 0) }
            if selectedUID == nil || blocks[selectedUID!] == nil {
                selectedUID = strongest.flatMap { (inputs[$0]?.level ?? 0) > 0 ? $0 : nil }; dwellSeconds = 0
            }
            dwellSeconds += seconds
            if let strongest, strongest != selectedUID,
               (inputs[strongest]?.level ?? 0) > max(0, (inputs[selectedUID ?? ""]?.level ?? 0) * 1.5) {
                if challenger == strongest { challengerSeconds += seconds }
                else { challenger = strongest; challengerSeconds = seconds }
                if dwellSeconds >= 1, challengerSeconds >= 0.4 {
                    selectedUID = strongest; dwellSeconds = 0; challenger = nil; challengerSeconds = 0
                }
            } else { challenger = nil; challengerSeconds = 0 }
            included = selectedUID.map { [$0] } ?? []
        }
        var result = Array(repeating: Float.zero, count: count)
        for uid in included {
            guard let block = blocks[uid] else { continue }
            for index in result.indices { result[index] += block[index] }
        }
        let peak = result.reduce(Float(1)) { max($0, abs($1)) }
        if peak > 1 { for index in result.indices { result[index] /= peak } }
        return AudioChunk(samples: result, format: format)
    }
}

public enum MeetingMicrophoneError: Error {
    case unsupportedFormat
}
