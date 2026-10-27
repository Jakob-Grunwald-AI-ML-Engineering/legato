import AVFAudio
import Foundation
import LegatoCore
import Synchronization

/// Converts tap buffers to a requested `AudioFormatSpec` (Float32, interleaved) and copies the
/// samples out, since the tap reuses its buffer. The lock serializes use of the stateful converter.
///
/// Input with more than two channels and a mono target is folded to mono by hand first (the system
/// converter has no layout to go by). `firstChannelOnly` takes channel 0, otherwise the channels are
/// averaged. Assumption (from the mac-audio spike, unverified on other hardware): a voice-processing
/// input reports many channels and channel 0 carries the processed voice, so averaging would dilute it.
final class BufferConverter: Sendable {
    private let converter: Mutex<AVAudioConverter>
    private let target: AVAudioFormat
    /// Set when multichannel input is folded to mono before the converter.
    private let monoFold: MonoFold?
    let spec: AudioFormatSpec

    fileprivate struct MonoFold: Sendable {
        let format: AVAudioFormat
        let firstChannelOnly: Bool
    }

    init?(from: AVAudioFormat, to spec: AudioFormatSpec, firstChannelOnly: Bool = false) {
        var source = from
        var fold: MonoFold?
        if from.channelCount > 2, spec.channelCount == 1, from.commonFormat == .pcmFormatFloat32 {
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: from.sampleRate, channels: 1, interleaved: false)
            else { return nil }
            source = mono
            fold = MonoFold(format: mono, firstChannelOnly: firstChannelOnly)
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: spec.sampleRate,
            channels: AVAudioChannelCount(spec.channelCount), interleaved: true),
            let c = AVAudioConverter(from: source, to: target)
        else { return nil }
        self.monoFold = fold
        // No priming: the default pre-roll drops a few frames from the first buffer, and the
        // stream has no use for resampler latency compensation.
        c.primeMethod = .none
        self.converter = Mutex(c)
        self.target = target
        self.spec = spec
    }

    func convert(_ original: AVAudioPCMBuffer) -> AudioChunk? {
        var input = original
        if let fold = monoFold {
            guard let mono = Self.fold(original, to: fold) else { return nil }
            input = mono
        }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feed = SliceFeeder(input)
        var error: NSError?
        let status = converter.withLock { $0.convert(to: out, error: &error) { wanted, outStatus in feed.next(wanted, outStatus) } }
        guard status != .error, let data = out.floatChannelData?[0] else { return nil }
        let count = Int(out.frameLength) * spec.channelCount
        return AudioChunk(samples: Array(UnsafeBufferPointer(start: data, count: count)), format: spec)
    }
}

extension BufferConverter {
    fileprivate static func fold(_ input: AVAudioPCMBuffer, to fold: MonoFold) -> AVAudioPCMBuffer? {
        let channels = Int(input.format.channelCount)
        let frames = Int(input.frameLength)
        guard let mono = AVAudioPCMBuffer(pcmFormat: fold.format, frameCapacity: input.frameLength),
            let dst = mono.floatChannelData?[0]
        else { return nil }
        let used = fold.firstChannelOnly ? 1 : channels
        if input.format.isInterleaved {
            guard let src = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)[0].mData?
                .assumingMemoryBound(to: Float.self)
            else { return nil }
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<used { sum += src[i * channels + c] }
                dst[i] = sum / Float(used)
            }
        } else {
            guard let src = input.floatChannelData else { return nil }
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<used { sum += src[c][i] }
                dst[i] = sum / Float(used)
            }
        }
        mono.frameLength = input.frameLength
        return mono
    }
}

/// Feeds one tap buffer to the converter's input block in the slices it asks for, then reports
/// "no data now". Handing over the whole buffer when the converter asked for fewer frames makes it
/// ignore the surplus (a 4800-frame buffer yields only 4096 frames' worth of output).
/// Used on a single thread within one `convert` call, so the unchecked conformance is safe.
private final class SliceFeeder: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var offset: AVAudioFrameCount = 0

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ wanted: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = buffer.frameLength - offset
        guard remaining > 0, let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: min(wanted, remaining)) else {
            status.pointee = .noDataNow
            return nil
        }
        let n = slice.frameCapacity
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp + Int(offset) * bytesPerFrame, Int(n) * bytesPerFrame)
        }
        for i in 0..<dst.count { dst[i].mDataByteSize = UInt32(Int(n) * bytesPerFrame) }
        slice.frameLength = n
        offset += n
        status.pointee = .haveData
        return slice
    }
}
