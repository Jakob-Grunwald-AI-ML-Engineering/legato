import Foundation
import LegatoCore
import Synchronization

public struct AudioInputCandidate: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case builtIn, wired, bluetooth, continuity, aggregate, virtual, other }
    public let id: String
    public let name: String
    public let kind: Kind
    public let available: Bool
    public let channels: Int?
    public let sampleRate: Double?
    public init(id: String, name: String, kind: Kind, available: Bool = true, channels: Int? = nil, sampleRate: Double? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.available = available
        self.channels = channels; self.sampleRate = sampleRate
    }
    public var isUsable: Bool {
        available && !id.isEmpty && kind != .aggregate && kind != .virtual && kind != .other
            && (channels.map { $0 > 0 } ?? true) && (sampleRate.map { $0.isFinite && $0 > 0 } ?? true)
    }
    public static func ordered(_ inputs: [Self]) -> [Self] {
        func rank(_ kind: Kind) -> Int {
            switch kind { case .builtIn: 0; case .wired: 1; case .bluetooth: 2; case .continuity: 3; default: 4 }
        }
        return inputs.filter(\.isUsable).sorted { a, b in
            rank(a.kind) == rank(b.kind) ? a.id < b.id : rank(a.kind) < rank(b.kind)
        }
    }
}

public struct AutomaticInputDiagnostics: Sendable, Codable {
    public var selected: AudioInputCandidate?
    public var candidates: [AudioInputCandidate] = []
    public var convertedSampleRate: Double = 0
    public var convertedChannels = 0
    public var buffers = 0
    public var frames = 0
    public var lastBufferUptime: Double?
    public var rms: Double = 0
    public var quality = InputSignalQuality()
    public var calibration = "idle"
    public var selectedReason = "none"
    public var recoveries = 0
    public var state = "idle"
    public var rejectedInputs: [String: String] = [:]
    public var qualityComparison = "not attempted"
    public var error: String?
    public init() {}
}

struct AutomaticInputHardware: Sendable {
    let candidates: @Sendable () async -> [AudioInputCandidate]
    let make: @Sendable (AudioInputCandidate) -> any AudioSource
    let isCurrent: @Sendable (AudioInputCandidate) async -> Bool
}

public enum AutomaticInputError: Error, Sendable, LocalizedError {
    case noUsableInput, noPCM
    public var errorDescription: String? {
        switch self {
        case .noUsableInput: "No working microphone input is available. Reconnect a microphone and tap Record again."
        case .noPCM: "The selected microphone stopped delivering audio. Tap Record to retry."
        }
    }
}

/// One physical input at a time. Built-in is preferred over headset input; silence is healthy PCM.
/// Missing/invalid buffers and native source failure trigger bounded same-stream recovery.
public actor AutomaticInputSource: ResumableAudioSource {
    public nonisolated let resumptions: AsyncStream<Void>
    private let resumeSink: AsyncStream<Void>.Continuation
    private nonisolated let diagnosticState = Mutex(AutomaticInputDiagnostics())
    public nonisolated var diagnostics: AutomaticInputDiagnostics { diagnosticState.withLock { $0 } }
    public static func availableInputs() async -> [AudioInputCandidate] { await AutomaticInputHardware.live.candidates() }
    private let hardware: AutomaticInputHardware
    private let timeout: Duration
    private let clock: @Sendable () -> Double
    private let preflight: Duration
    private var qualityMeter = InputQualityMeter()
    private var clippingWindows = 0
    private var qualityTrialUsed = false
    private let router = TapRouter()
    private var source: (any AudioSource)?
    private var selected: AudioInputCandidate?
    private var pump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var format: AudioFormatSpec?
    private var generation = 0
    private var routeGeneration = 0
    private var attached = false
    private var connecting = false
    private var fault = false
    private var failed: Set<String> = []
    private var retried: Set<String> = []
    private var recoveryCount = 0

    public init() {
        hardware = .live; timeout = .seconds(2); preflight = .milliseconds(250); clock = { ProcessInfo.processInfo.systemUptime }
        (resumptions, resumeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    init(hardware: AutomaticInputHardware, timeout: Duration = .milliseconds(100), preflight: Duration = .zero,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.hardware = hardware; self.timeout = timeout; self.preflight = preflight; self.clock = clock
        (resumptions, resumeSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }
    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stop()
        try Task.checkCancellation()
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else { throw MicSourceError.invalidInputFormat }
        let token = generation
        self.format = format; attached = true; failed = []; retried = []; recoveryCount = 0; qualityTrialUsed = false
        diagnosticState.withLock { $0 = AutomaticInputDiagnostics(); $0.state = "starting" }
        let stream = makeStream()
        do { try await connect(format: format, token: token) }
        catch {
            if token == generation { await stop(); diagnosticState.withLock { $0.state = "failed"; $0.error = error.localizedDescription } }
            throw error
        }
        installWatchdog(token: token)
        return stream
    }
    public func route() async throws -> AsyncStream<AudioChunk> {
        guard let format, source != nil else { throw MicSourceError.notArmed }
        attached = true
        let stream = makeStream(), token = generation
        if fault || stale {
            try await recover(token: token, format: format)
        } else { installWatchdog(token: token) }
        return stream
    }
    public func detach() async { attached = false; watchdog?.cancel(); watchdog = nil; router.setSink(nil) }
    public func stop() async {
        generation += 1; routeGeneration += 1; attached = false; connecting = false; format = nil
        watchdog?.cancel(); watchdog = nil
        let old = source, oldPump = pump
        source = nil; selected = nil; pump = nil
        oldPump?.cancel(); router.setSink(nil)
        await old?.stop(); await oldPump?.value
        diagnosticState.withLock { $0.state = "idle" }
    }
    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(256))
        router.setSink(continuation); return stream
    }
    private var timeoutSeconds: Double { Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18 }
    private var stale: Bool { diagnosticState.withLock { state in state.lastBufferUptime.map { clock() - $0 > timeoutSeconds } ?? true } }
    private func connect(format: AudioFormatSpec, token: Int, only: [AudioInputCandidate]? = nil) async throws {
        connecting = true
        defer { if token == generation { connecting = false } }
        let candidates = await hardware.candidates()
        diagnosticState.withLock { $0.candidates = candidates }
        for candidate in AudioInputCandidate.ordered(only ?? candidates) where !failed.contains(candidate.id) {
            try check(token)
            let fresh = hardware.make(candidate)
            source = fresh; selected = candidate; routeGeneration += 1
            let route = routeGeneration
            fault = false; qualityMeter = InputQualityMeter(); clippingWindows = 0
            diagnosticState.withLock {
                $0.selected = candidate; $0.state = "starting"; $0.error = nil
                $0.buffers = 0; $0.frames = 0; $0.lastBufferUptime = nil; $0.rms = 0
                $0.quality = InputSignalQuality(); $0.calibration = "checking"
            }
            do {
                let chunks = try await fresh.start(format: format)
                try check(token)
                pump = Task { [weak self] in
                    for await chunk in chunks {
                        guard !Task.isCancelled, await self?.receive(chunk, token: token, route: route) == true else { break }
                    }
                    await self?.ended(token: token, route: route)
                }
                let deadline = ContinuousClock.now + timeout
                while ContinuousClock.now < deadline {
                    try check(token)
                    if fault { throw AutomaticInputError.noPCM }
                    let minimumFrames = format.sampleRate * (Double(preflight.components.seconds) + Double(preflight.components.attoseconds) / 1e18)
                    if diagnosticState.withLock({ $0.buffers > 0 && Double($0.frames) >= minimumFrames }) {
                        let current = await hardware.candidates().first { $0.id == candidate.id }
                        try check(token)
                        diagnosticState.withLock {
                            $0.selected = current ?? candidate; $0.state = "capturing"; $0.calibration = "ready-" + $0.quality.state
                            $0.selectedReason = candidate.kind == .builtIn ? "built-in preference, measured PCM" : "physical fallback, measured PCM"
                        }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw AutomaticInputError.noPCM
            } catch {
                await fresh.stop()
                pump?.cancel(); pump = nil
                try check(token)
                failed.insert(candidate.id)
                diagnosticState.withLock { $0.error = error.localizedDescription; $0.rejectedInputs[candidate.id] = error.localizedDescription }
                source = nil
            }
        }
        throw AutomaticInputError.noUsableInput
    }
    private func receive(_ chunk: AudioChunk, token: Int, route: Int) async -> Bool {
        guard token == generation, route == routeGeneration, let format else { return false }
        guard chunk.format == format, !chunk.samples.isEmpty,
              chunk.samples.count % max(1, format.channelCount) == 0, chunk.samples.allSatisfy(\.isFinite) else {
            if !chunk.samples.isEmpty { fault = true; return false }
            return true
        }
        let quality = qualityMeter.observe(chunk)
        if quality.seconds >= 2 {
            clippingWindows = quality.clippedFraction >= 0.15 ? clippingWindows + 1 : 0
            qualityMeter = InputQualityMeter()
        }
        diagnosticState.withLock {
            $0.buffers += 1; $0.frames += chunk.samples.count / max(1, format.channelCount)
            $0.lastBufferUptime = clock(); $0.rms = quality.rms; $0.quality = quality
            $0.convertedSampleRate = format.sampleRate; $0.convertedChannels = format.channelCount
        }
        if attached { router.handle(chunk) }
        return true
    }
    private func ended(token: Int, route: Int) async {
        guard token == generation, route == routeGeneration else { return }
        fault = true
        guard !connecting, attached, format != nil else { return }
        Task { [weak self] in await self?.checkHealth(token: token) }
    }
    private func installWatchdog(token: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self, timeout] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: timeout / 2) } catch { return }
                await self?.checkHealth(token: token)
            }
        }
    }
    private func checkHealth(token: Int) async {
        guard token == generation, attached, !connecting, let format else { return }
        let routeChanged = if let selected { await !hardware.isCurrent(selected) } else { true }
        guard token == generation, !connecting else { return }
        if !fault && !stale && !routeChanged && clippingWindows >= 2 && !qualityTrialUsed {
            await compareClippingAlternative(token: token, format: format)
            return
        }
        guard fault || stale || routeChanged else { return }
        do { try await recover(token: token, format: format) } catch { await failIfCurrent(token, error: error) }
    }
    /// One sequential comparison per requested recording, only after four seconds of severe clipping.
    /// Quiet audio is never classified as broken or accepted as evidence of clearer speech.
    private func compareClippingAlternative(token: Int, format: AudioFormatSpec) async {
        guard let original = selected else { return }
        let baseline = diagnostics.quality
        let alternatives = AudioInputCandidate.ordered(await hardware.candidates()).filter {
            $0.id != original.id && !failed.contains($0.id)
        }
        guard token == generation, attached, !connecting, let alternate = alternatives.first else { return }
        qualityTrialUsed = true; connecting = true
        diagnosticState.withLock { $0.qualityComparison = "checking lower distortion" }
        let old = source; source = nil; routeGeneration += 1; pump?.cancel(); pump = nil
        await old?.stop()
        do {
            try check(token)
            try await connect(format: format, token: token, only: [alternate])
            let measured = diagnostics.quality
            if measured.rms > 0 && measured.clippedFraction < baseline.clippedFraction / 2 {
                diagnosticState.withLock {
                    $0.selectedReason = "measured lower clipping; speech clarity unranked"
                    $0.qualityComparison = "lower distortion accepted"
                }
            } else {
                let trial = source; source = nil; routeGeneration += 1; pump?.cancel(); pump = nil
                await trial?.stop()
                try check(token)
                try await connect(format: format, token: token, only: [original])
                diagnosticState.withLock { $0.qualityComparison = "no measured improvement; original restored" }
            }
            resumeSink.yield()
        } catch {
            guard token == generation else { return }
            // A failed trial must not sacrifice the previously working input.
            do {
                try await connect(format: format, token: token, only: [original])
                diagnosticState.withLock { $0.qualityComparison = "trial failed; original restored" }
                resumeSink.yield()
            } catch { await failIfCurrent(token, error: error) }
        }
    }
    private func recover(token: Int, format: AudioFormatSpec) async throws {
        try check(token)
        guard !connecting, recoveryCount < 3 else { throw AutomaticInputError.noPCM }
        connecting = true; recoveryCount += 1
        diagnosticState.withLock { $0.state = "recovering"; $0.recoveries = recoveryCount }
        if let selected, !retried.insert(selected.id).inserted { failed.insert(selected.id) }
        let old = source, oldPump = pump
        source = nil; pump = nil; routeGeneration += 1
        oldPump?.cancel(); await old?.stop()
        try check(token)
        try await connect(format: format, token: token)
        resumeSink.yield()
        installWatchdog(token: token)
    }
    private func failIfCurrent(_ token: Int, error: any Error) async {
        guard token == generation else { return }
        watchdog?.cancel(); watchdog = nil
        let old = source; source = nil; pump?.cancel(); pump = nil
        await old?.stop()
        guard token == generation else { return }
        diagnosticState.withLock { $0.state = "failed"; $0.error = error.localizedDescription }
        router.setSink(nil)
    }
    private func check(_ token: Int) throws { try Task.checkCancellation(); guard token == generation else { throw CancellationError() } }
}
