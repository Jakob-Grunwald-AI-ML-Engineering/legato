#if os(macOS)
import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import LegatoCore
import Synchronization

/// What the app can show about the system-audio tap.
public enum SystemAudioStatus: Sendable, Equatable {
    case running
    /// The tap is being rebuilt (output device changed, or the watchdog saw only zeros).
    case rebuilding
    /// Another process is playing but the tap delivers only zeros, even after a rebuild:
    /// check the System Audio Recording permission.
    case systemAudioSilent
    case failed(String)
}

public enum SystemAudioSourceError: Error, Sendable, Equatable {
    case notArmed
    case converterUnavailable
    /// A Core Audio call failed (`call` names it).
    case coreAudio(call: String, status: Int32)
}

/// System audio (everything except this process) through a Core Audio process tap, macOS 14.2+.
/// Chunks come out in the requested format, like `MicSource`.
///
/// Start it after the microphone: our own process only has a Core Audio process object once it has
/// touched Core Audio, and the tap excludes it (so a meeting window playing sound cannot feed back).
/// If the object is still missing, the lookup is retried a few times, then the tap runs without the exclusion.
///
/// The tap is rebuilt when the default output device changes, when its sample rate changes (AirPods leaving
/// A2DP for the headset profile once the mic starts), and when `TapWatchdog` sees only zeros while another
/// process plays. The converter is built for the rate the aggregate device runs at (`TapRate`), which is
/// read after the device exists and checked again every second. The first needs no permission; the first start of a tap triggers the
/// System Audio Recording prompt. Not covered by unit tests (real hardware); the app self-test does.
public final class SystemAudioSource: ResumableAudioSource {
    private struct Handles {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        /// The sample rate the converter was built for.
        var rate = 0.0
        /// Devices whose nominal sample rate is watched, and the one listener on them.
        var rateDevices: [AudioObjectID] = []
        var rateListener: ListenerBox?
    }

    private struct State {
        var armed = false
        var format: AudioFormatSpec?
        var handles = Handles()
        var rebuilding = false
        var generation = 0
        var listener: ListenerBox?
        var poller: Task<Void, Never>?
    }

    /// Lets the property-listener block cross into the lock. Safe: it is only stored, then handed back to remove.
    private final class ListenerBox: @unchecked Sendable {
        let block: AudioObjectPropertyListenerBlock
        init(_ block: @escaping AudioObjectPropertyListenerBlock) { self.block = block }
    }

    /// Watchdog state shared with the IO thread.
    private final class Watch: Sendable {
        private let dog = Mutex(TapWatchdog())
        private let outputting = Mutex(false)
        func setOutputting(_ v: Bool) { outputting.withLock { $0 = v } }
        func observe(allZero: Bool, at now: TimeInterval) -> TapWatchdog.Action {
            let other = outputting.withLock { $0 }
            return dog.withLock { $0.observe(allZero: allZero, otherProcessOutputting: other, at: now) }
        }
        func reset() { dog.withLock { $0 = TapWatchdog() } }
    }

    /// Own-process exclusion lookup: 5 tries, 100 ms apart.
    static let exclusionAttempts = 5
    static let exclusionDelay: Duration = .milliseconds(100)

    /// Status changes, for the app to show. One consumer.
    public let statuses: AsyncStream<SystemAudioStatus>

    /// Yields each time the tap was rebuilt and delivers again, so a meeting can fill the time it was away.
    public let resumptions: AsyncStream<Void>

    private let statusSink: AsyncStream<SystemAudioStatus>.Continuation
    private let resumeSink: AsyncStream<Void>.Continuation
    private let state = Mutex(State())
    private let router = TapRouter()
    private let watch = Watch()
    private let queue = DispatchQueue(label: "legato.systemaudio", qos: .userInitiated)
    private let ownPID = getpid()

    public init() {
        (statuses, statusSink) = AsyncStream.makeStream(of: SystemAudioStatus.self)
        (resumptions, resumeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        await stop()
        state.withLock { s in
            s.armed = true
            s.format = format
            s.generation += 1
        }
        do {
            try await buildTap()
        } catch {
            await stop()
            throw error
        }
        installListener()
        startPolling()
        statusSink.yield(.running)
        return makeStream()
    }

    public func route() async throws -> AsyncStream<AudioChunk> {
        guard state.withLock({ $0.armed }) else { throw SystemAudioSourceError.notArmed }
        return makeStream()
    }

    public func detach() async {
        router.setSink(nil)
    }

    public func stop() async {
        router.setSink(nil)
        let (listener, poller) = state.withLock { s -> (ListenerBox?, Task<Void, Never>?) in
            s.armed = false
            s.generation += 1
            defer { s.listener = nil; s.poller = nil }
            return (s.listener, s.poller)
        }
        poller?.cancel()
        if let listener {
            var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener.block)
        }
        tearDownTap()
    }

    private func makeStream() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        router.setSink(continuation)
        return stream
    }

    // MARK: Tap lifecycle

    private func buildTap() async throws {
        guard let spec = state.withLock({ $0.format }) else { throw SystemAudioSourceError.notArmed }
        var excluded: [AudioObjectID] = []
        for attempt in 0..<Self.exclusionAttempts {
            if let own = Self.processObject(pid: ownPID) {
                excluded = [own]
                break
            }
            if attempt < Self.exclusionAttempts - 1 { try await Task.sleep(for: Self.exclusionDelay) }
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "Legato system audio"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var handles = Handles()
        func fail(_ call: String, _ status: OSStatus) -> SystemAudioSourceError {
            Self.destroy(handles, queue: queue)
            return .coreAudio(call: call, status: status)
        }
        var err = AudioHardwareCreateProcessTap(desc, &handles.tap)
        guard err == noErr else { throw fail("AudioHardwareCreateProcessTap", err) }

        var outputID = AudioDeviceID(kAudioObjectUnknown)
        err = Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &outputID)
        guard err == noErr else { throw fail("DefaultOutputDevice", err) }
        guard let outputUID = Self.string(outputID, kAudioDevicePropertyDeviceUID) else {
            throw fail("kAudioDevicePropertyDeviceUID", -1)
        }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LegatoSystemTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]
            ],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &handles.aggregate)
        guard err == noErr else { throw fail("AudioHardwareCreateAggregateDevice", err) }

        // The format is read now that the aggregate device exists: before, the tap can still describe the
        // output as it was (48 kHz) while the device already runs at another rate (24 kHz headset).
        var asbd = AudioStreamBasicDescription()
        err = Self.read(handles.tap, kAudioTapPropertyFormat, &asbd)
        guard err == noErr else { throw fail("kAudioTapPropertyFormat", err) }
        var nominal = Float64(0)
        let nominalErr = Self.read(handles.aggregate, kAudioDevicePropertyNominalSampleRate, &nominal)
        asbd.mSampleRate = TapRate.effective(reported: asbd.mSampleRate, deviceNominal: nominalErr == noErr ? nominal : nil)
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd),
            let converter = BufferConverter(from: tapFormat, to: spec)
        else { throw fail("tap format", -1) }
        handles.rate = asbd.mSampleRate

        let block = Self.ioBlock(
            format: tapFormat, converter: converter, router: router, watch: watch,
            onAction: { [weak self] action in self?.handle(action) })
        err = AudioDeviceCreateIOProcIDWithBlock(&handles.proc, handles.aggregate, queue, block)
        guard err == noErr else { throw fail("AudioDeviceCreateIOProcIDWithBlock", err) }
        // The permission prompt appears on the first start of a device that contains a tap.
        err = AudioDeviceStart(handles.aggregate, handles.proc)
        guard err == noErr else { throw fail("AudioDeviceStart", err) }

        watch.reset()
        installRateListener(on: [outputID, handles.aggregate], into: &handles)
        state.withLock { $0.handles = handles }
    }

    /// Rebuilds when the output device or the aggregate device changes its nominal sample rate.
    private func installRateListener(on devices: [AudioObjectID], into handles: inout Handles) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.rebuildIfRateChanged() }
        }
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        for device in devices where AudioObjectAddPropertyListenerBlock(device, &addr, queue, listener) == noErr {
            handles.rateDevices.append(device)
        }
        if !handles.rateDevices.isEmpty { handles.rateListener = ListenerBox(listener) }
    }

    /// The listener and the once-a-second check both land here; a rate the tap was built for does nothing.
    private func rebuildIfRateChanged() async {
        let (aggregate, built) = state.withLock { ($0.handles.aggregate, $0.handles.rate) }
        guard aggregate != kAudioObjectUnknown else { return }
        var nominal = Float64(0)
        guard Self.read(aggregate, kAudioDevicePropertyNominalSampleRate, &nominal) == noErr else { return }
        if TapRate.needsRebuild(built: built, deviceNominal: nominal) { await rebuild() }
    }

    private func tearDownTap() {
        let handles = state.withLock { s -> Handles in
            defer { s.handles = Handles() }
            return s.handles
        }
        Self.destroy(handles, queue: queue)
    }

    private static func destroy(_ h: Handles, queue: DispatchQueue) {
        if let listener = h.rateListener {
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            for device in h.rateDevices { AudioObjectRemovePropertyListenerBlock(device, &addr, queue, listener.block) }
        }
        if h.aggregate != kAudioObjectUnknown {
            AudioDeviceStop(h.aggregate, h.proc)
            if let proc = h.proc { AudioDeviceDestroyIOProcID(h.aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(h.aggregate)
        }
        if h.tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(h.tap) }
    }

    /// Tears the tap down and builds it again, once at a time. A no-op after `stop()`.
    private func rebuild() async {
        let generation = state.withLock { s -> Int? in
            guard s.armed, !s.rebuilding else { return nil }
            s.rebuilding = true
            return s.generation
        }
        guard let generation else { return }
        statusSink.yield(.rebuilding)
        tearDownTap()
        var failure: SystemAudioStatus = .running
        do { try await buildTap() } catch { failure = .failed("\(error)") }
        let stale = state.withLock { s -> Bool in
            s.rebuilding = false
            return s.generation != generation || !s.armed
        }
        if stale {
            tearDownTap()
        } else {
            statusSink.yield(failure)
            if failure == .running { resumeSink.yield() }
        }
    }

    private func handle(_ action: TapWatchdog.Action) {
        switch action {
        case .none: break
        case .rebuild: Task { await rebuild() }
        case .reportSilent: statusSink.yield(.systemAudioSilent)
        }
    }

    // MARK: Output device changes and the process list

    private func installListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.rebuild() }
        }
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let err = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        if err == noErr { state.withLock { $0.listener = ListenerBox(listener) } }
    }

    /// Once a second: refreshes "does another process have output running" for the watchdog and checks the sample rate.
    private func startPolling() {
        let (watch, own) = (watch, ownPID)
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let others = (try? Self.outputPIDs()) ?? []
                watch.setOutputting(others.contains { $0 != own })
                await self?.rebuildIfRateChanged() // backs up the property listener
                try? await Task.sleep(for: .seconds(1))
            }
        }
        state.withLock { $0.poller = task }
    }

    /// Built outside any actor: a closure formed in an isolated context inherits that isolation,
    /// and Swift 6 traps when Core Audio calls it on its own thread.
    nonisolated private static func ioBlock(
        format: AVAudioFormat, converter: BufferConverter, router: TapRouter, watch: Watch,
        onAction: @escaping @Sendable (TapWatchdog.Action) -> Void
    ) -> AudioDeviceIOBlock {
        { _, inData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inData, deallocator: nil) else { return }
            let action = watch.observe(allZero: isAllZero(buffer), at: ProcessInfo.processInfo.systemUptime)
            if action != .none { onAction(action) }
            if let chunk = converter.convert(buffer) { router.handle(chunk) }
        }
    }

    private static func isAllZero(_ buffer: AVAudioPCMBuffer) -> Bool {
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(Int(audio.mDataByteSize) / MemoryLayout<Float>.size) where p[i] != 0 { return false }
        }
        return true
    }

    // MARK: Core Audio property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &result)
        return (err == noErr && result != kAudioObjectUnknown) ? result : nil
    }

    /// PIDs of processes with output running (the same list `MicInUseMonitor` reads for input).
    private static func outputPIDs() throws -> [pid_t] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard err == noErr else { throw SystemAudioSourceError.coreAudio(call: "ProcessObjectList size", status: err) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard err == noErr else { throw SystemAudioSourceError.coreAudio(call: "ProcessObjectList", status: err) }
        return ids.compactMap { id in
            var running: UInt32 = 0
            var pid: pid_t = 0
            guard read(id, kAudioProcessPropertyIsRunningOutput, &running) == noErr, running != 0,
                read(id, kAudioProcessPropertyPID, &pid) == noErr
            else { return nil }
            return pid
        }
    }
}
#endif
