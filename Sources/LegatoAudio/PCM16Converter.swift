import AVFAudio
import Foundation
import LegatoCore

public enum PCM16ConversionError: Error { case invalidFormat, conversionFailed }

/// Stateful system resampler, with mono downmix and explicit little-endian output for Soniox.
public struct PCM16Converter: Sendable {
    private var inputFormat: AudioFormatSpec?
    private var converter: BufferConverter?
    public init() {}
    public mutating func convert(_ chunk: AudioChunk) throws -> Data {
        let spec = chunk.format
        guard spec.sampleRate.isFinite, spec.sampleRate > 0, spec.channelCount > 0,
              chunk.samples.count % spec.channelCount == 0 else { throw PCM16ConversionError.invalidFormat }
        guard !chunk.samples.isEmpty else { return Data() }
        var samples = chunk.samples
        if spec != AudioFormatSpec(sampleRate: 16000, channelCount: 1) {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: spec.sampleRate,
                                             channels: AVAudioChannelCount(spec.channelCount), interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / spec.channelCount))
            else { throw PCM16ConversionError.invalidFormat }
            if inputFormat != spec {
                converter = BufferConverter(from: format, to: AudioFormatSpec(sampleRate: 16000, channelCount: 1))
                inputFormat = spec
            }
            buffer.frameLength = buffer.frameCapacity
            guard let destination = buffer.floatChannelData?[0] else { throw PCM16ConversionError.conversionFailed }
            samples.withUnsafeBufferPointer { source in destination.update(from: source.baseAddress!, count: source.count) }
            guard let result = converter?.convert(buffer) else { throw PCM16ConversionError.conversionFailed }
            samples = result.samples
        }
        var output = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
            var value = Int16(max(-32768, min(32767, Int((clamped * 32768).rounded())))).littleEndian
            withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        return output
    }
}
