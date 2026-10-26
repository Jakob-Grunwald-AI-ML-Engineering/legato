import AVFAudio
import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct BufferConverterMultichannelTests {
    /// 16 kHz, 3 channels: ch0 = 0.6, ch1 = 0.0, ch2 = 0.0 (constant), so the mono result tells which rule ran.
    private func threeChannel(interleaved: Bool) throws -> AVAudioPCMBuffer {
        // More than two channels need an explicit layout; "unknown, 3 channels" is what a voice-processing input looks like.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | 3))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, interleaved: interleaved, channelLayout: layout)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600))
        buf.frameLength = 1600
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        if interleaved {
            let p = try #require(abl[0].mData?.assumingMemoryBound(to: Float.self))
            for i in 0..<1600 { p[i * 3] = 0.6; p[i * 3 + 1] = 0; p[i * 3 + 2] = 0 }
        } else {
            let p = try #require(buf.floatChannelData)
            for i in 0..<1600 { p[0][i] = 0.6; p[1][i] = 0; p[2][i] = 0 }
        }
        return buf
    }

    private let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)

    @Test(arguments: [false, true]) func threeChannelsAverageToMono(interleaved: Bool) throws {
        let buf = try threeChannel(interleaved: interleaved)
        let conv = try #require(BufferConverter(from: buf.format, to: spec))
        let chunk = try #require(conv.convert(buf))
        #expect(chunk.format == spec)
        #expect(abs(chunk.samples.count - 1600) <= 1)
        #expect(chunk.samples.allSatisfy { abs($0 - 0.2) < 0.01 })
    }

    @Test func firstChannelOnlyTakesChannelZero() throws {
        let buf = try threeChannel(interleaved: false)
        let conv = try #require(BufferConverter(from: buf.format, to: spec, firstChannelOnly: true))
        let chunk = try #require(conv.convert(buf))
        #expect(chunk.samples.allSatisfy { abs($0 - 0.6) < 0.01 })
    }
}
