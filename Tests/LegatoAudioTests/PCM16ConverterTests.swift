import Foundation
import Testing
import LegatoCore
@testable import LegatoAudio

@Suite struct PCM16ConverterTests {
    @Test func sineWaveHasExpectedLittleEndianSamples() throws {
        var converter = PCM16Converter()
        let samples: [Float] = (0..<8).map { sin(Float($0) * .pi / 2) }
        let bytes = try converter.convert(AudioChunk(samples: samples, format: .init(sampleRate: 16000, channelCount: 1)))
        #expect(Array(bytes) == [0,0,255,127,0,0,0,128,0,0,255,127,0,0,0,128])
    }
    @Test func resamplerPreservesStreamingStereoAudio() throws {
        var converter = PCM16Converter()
        let stereo: [Float] = (0..<4800).flatMap { i in
            let value = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.5
            return [value, value]
        }
        let chunks = try (0..<3).map { _ in try converter.convert(AudioChunk(samples: stereo, format: .init(sampleRate: 48000, channelCount: 2))) }
        #expect(chunks.allSatisfy { !$0.isEmpty })
        #expect(abs(chunks.reduce(0) { $0 + $1.count } - 9600) < 128)
        #expect(chunks[1].contains { $0 != 0 })
    }
}
