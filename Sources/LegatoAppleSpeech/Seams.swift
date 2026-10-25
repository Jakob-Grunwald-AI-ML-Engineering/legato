import AVFAudio
import Foundation
import LegatoCore

/// Resolves the session locale: the request, else the device locale, mapped to a supported equivalent.
enum LocaleResolver {
    static func resolve(
        requested: Locale?,
        current: Locale = .current,
        supported: (Locale) async -> Locale?
    ) async throws -> Locale {
        let wanted = requested ?? current
        guard let match = await supported(wanted) else {
            throw AppleSpeechError.unsupportedLocale(wanted.identifier)
        }
        return match
    }
}

/// `TranscriptAssembler` appends final text verbatim, so the engine supplies the separator
/// between phrases. Volatile text is separated the same way but never counts as committed.
struct PhraseSpacer: Sendable {
    private var committedEndsWithSpace = true  // true while nothing is committed

    mutating func apply(_ text: String, isFinal: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let needsSpace = !committedEndsWithSpace && !(text.first?.isWhitespace ?? false)
        let out = needsSpace ? " " + text : text
        if isFinal { committedEndsWithSpace = out.last?.isWhitespace ?? true }
        return out
    }
}

/// Packs Float32 chunks into PCM buffers in the analyzer's format.
enum PCMPacker {
    static func buffer(from chunk: AudioChunk, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = max(chunk.format.channelCount, 1)
        let frames = chunk.samples.count / channels
        guard frames > 0 else { return nil }
        if format.channelCount == AVAudioChannelCount(channels), format.sampleRate == chunk.format.sampleRate, channels == 1,
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        {
            switch format.commonFormat {
            case .pcmFormatFloat32:
                guard let dst = out.floatChannelData?[0] else { return nil }
                chunk.samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames) }
            case .pcmFormatInt16:
                guard let dst = out.int16ChannelData?[0] else { return nil }
                for i in 0..<frames {
                    let v = max(-1, min(1, chunk.samples[i])) * Float(Int16.max)
                    dst[i] = Int16(v.rounded())
                }
            default:
                return convert(chunk, frames: frames, to: format)
            }
            out.frameLength = AVAudioFrameCount(frames)
            return out
        }
        return convert(chunk, frames: frames, to: format)
    }

    /// Slow path for rate/channel/sample-type mismatches.
    private static func convert(_ chunk: AudioChunk, frames: Int, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let src = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: chunk.format.sampleRate,
                channels: AVAudioChannelCount(chunk.format.channelCount), interleaved: true),
            let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(frames)),
            let dst = inBuf.floatChannelData?[0],
            let converter = AVAudioConverter(from: src, to: format)
        else { return nil }
        chunk.samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: chunk.samples.count) }
        inBuf.frameLength = AVAudioFrameCount(frames)
        let ratio = format.sampleRate / src.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64) else { return nil }
        let feed = OneShot(inBuf)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in feed.take(outStatus) }
        return status == .error ? nil : out
    }
}

/// Hands one buffer to a synchronous converter callback exactly once (single-threaded use).
private final class OneShot: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let b = buffer else { status.pointee = .noDataNow; return nil }
        buffer = nil
        status.pointee = .haveData
        return b
    }
}
