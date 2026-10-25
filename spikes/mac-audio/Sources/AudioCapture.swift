import AVFoundation
import AudioToolbox
import CoreAudio
import os

// MARK: - Shared helpers

/// Converts any PCM buffer to the 16 kHz mono Float32 that FluidAudio's ASR expects.
/// One instance per stream; not thread-safe (each is used from a single audio queue).
final class Resampler16k: @unchecked Sendable {
    static let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.target)
            inputFormat = buffer.format
        }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ptr = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
    }
}

/// Per-stream capture statistics, measured on the raw (native-format) buffers.
struct StreamStats: Sendable, Codable {
    var nativeFormat = ""
    var buffers = 0
    var zeroBuffers = 0  // buffers whose every sample is exactly 0.0
    var frames16k = 0
    var sumSquares = 0.0
    var peak: Float = 0
    var rms: Double { frames16k == 0 ? 0 : (sumSquares / Double(frames16k)).squareRoot() }
}

final class StatsBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: StreamStats())

    func record(raw: AVAudioPCMBuffer, samples16k: [Float]) {
        var allZero = true
        let abl = UnsafeMutableAudioBufferListPointer(raw.mutableAudioBufferList)
        scan: for buf in abl {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n where p[i] != 0 {
                allZero = false
                break scan
            }
        }
        var ss = 0.0
        var peak: Float = 0
        for s in samples16k {
            ss += Double(s * s)
            peak = max(peak, abs(s))
        }
        let fmt = "\(raw.format.sampleRate) Hz, \(raw.format.channelCount) ch"
        let (zero, energy, top) = (allZero, ss, peak)
        lock.withLock {
            $0.nativeFormat = fmt
            $0.buffers += 1
            if zero { $0.zeroBuffers += 1 }
            $0.frames16k += samples16k.count
            $0.sumSquares += energy
            $0.peak = max($0.peak, top)
        }
    }

    var snapshot: StreamStats { lock.withLock { $0 } }
}

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Microphone (AVAudioEngine)

final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler = Resampler16k()
    let stats = StatsBox()

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError("mic: input format has 0 Hz (no input device or no permission)") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [resampler, stats] buffer, _ in
            let samples = resampler.convert(buffer)
            stats.record(raw: buffer, samples16k: samples)
            onSamples(samples)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - System audio (Core Audio process tap, macOS 14.2+)

final class SystemAudioTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "legato.systap", qos: .userInitiated)
    private let resampler = Resampler16k()
    let stats = StatsBox()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var excludedOwnProcess = false

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        // Global stereo mixdown of every process except ours (we play nothing, but this avoids feedback if we ever do).
        var excluded: [AudioObjectID] = []
        if let own = Self.processObject(pid: getpid()) {
            excluded = [own]
            excludedOwnProcess = true
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "Legato spike tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CaptureError("AudioHardwareCreateProcessTap failed: OSStatus \(err)") }

        var asbd = try Self.get(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError("bad tap format") }

        let outputID = try Self.get(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
            AudioDeviceID(kAudioObjectUnknown))
        let outputUID = try Self.getString(outputID, kAudioDevicePropertyDeviceUID)

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LegatoSpikeTap",
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
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard err == noErr else { throw CaptureError("AudioHardwareCreateAggregateDevice failed: OSStatus \(err)") }

        let resampler = resampler
        let stats = stats
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inData, deallocator: nil) else { return }
            let samples = resampler.convert(buffer)
            stats.record(raw: buffer, samples16k: samples)
            onSamples(samples)
        }
        guard err == noErr else { throw CaptureError("AudioDeviceCreateIOProcIDWithBlock failed: OSStatus \(err)") }
        // The TCC prompt for system-audio capture appears on the first start of a device that contains a tap.
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw CaptureError("AudioDeviceStart failed: OSStatus \(err)") }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    // MARK: Core Audio property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr else { throw CaptureError("AudioObjectGetPropertyData(\(selector)) failed: OSStatus \(err)") }
        return value
    }

    private static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { throw CaptureError("get string \(selector) failed: OSStatus \(err)") }
        return value.takeRetainedValue() as String
    }

    /// Our own process only has an audio-object once it has touched Core Audio (the mic engine does that first).
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &result)
        return (err == noErr && result != kAudioObjectUnknown) ? result : nil
    }
}
