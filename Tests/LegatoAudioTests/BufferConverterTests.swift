import AVFAudio
import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct BufferConverterTests {
    @Test func converts48kStereoTo16kMono() throws {
        let inFmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let frames: AVAudioFrameCount = 4800 // 100 ms
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames))
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = try #require(buf.floatChannelData?[ch])
            for i in 0..<Int(frames) { p[i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 48_000) }
        }
        let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
        let conv = try #require(BufferConverter(from: inFmt, to: spec))
        let chunk = try #require(conv.convert(buf))
        #expect(chunk.format == spec)
        #expect(abs(chunk.samples.count - 1600) <= 1)
        #expect(chunk.samples.contains { abs($0) > 0.1 })
    }

    @Test func passesThroughMatchingFormat() throws {
        let fmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 160))
        buf.frameLength = 160
        let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
        let conv = try #require(BufferConverter(from: fmt, to: spec))
        let chunk = try #require(conv.convert(buf))
        #expect(chunk.samples.count == 160)
    }
}
