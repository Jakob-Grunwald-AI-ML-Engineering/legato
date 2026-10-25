import AVFAudio
import Foundation
import LegatoCore
import Speech
import Testing
@testable import LegatoAppleSpeech

private let realEngineEnabled = ProcessInfo.processInfo.environment["LEGATO_REAL_ENGINE"] == "1"

/// Reads the fixture and resamples it to Float32 mono at `spec`.
private func fixtureSamples(spec: AudioFormatSpec) throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: "hello-en", withExtension: "aiff", subdirectory: "Fixtures"))
    let file = try AVAudioFile(forReading: url)
    let inBuf = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: inBuf)
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: spec.sampleRate, channels: 1, interleaved: true))
    let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
    let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * spec.sampleRate / file.processingFormat.sampleRate) + 1024
    let out = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
    nonisolated(unsafe) var consumed = false  // single-threaded converter callback
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if consumed { status.pointee = .endOfStream; return nil }
        consumed = true
        status.pointee = .haveData
        return inBuf
    }
    #expect(error == nil)
    return Array(UnsafeBufferPointer(start: try #require(out.floatChannelData?[0]), count: Int(out.frameLength)))
}

@Suite("Real SpeechTranscriber engine", .serialized)
struct RealEngineTests {
    @Test(.enabled(if: realEngineEnabled, "set LEGATO_REAL_ENGINE=1 to run against the on-device model"))
    func transcribesTheFixture() async throws {
        let locale = Locale(identifier: "en_US")
        let engine = AppleSpeechEngine()
        #expect(engine.id == "apple-speech")

        do {
            _ = try await engine.prepare(locale: locale)
        } catch DictationError.assetsNotInstalled {
            // Local only: fetch the model, then prepare again.
            for await p in engine.installAssets(locale: locale) { print("asset install progress: \(p)") }
        }
        let spec = try await engine.prepare(locale: locale)
        #expect(spec.channelCount == 1)

        let samples = try fixtureSamples(spec: spec)
        print("fixture: \(samples.count) samples @ \(spec.sampleRate) Hz, peak \(samples.map { abs($0) }.max() ?? 0)")
        let chunkSize = Int(spec.sampleRate / 10)
        let (input, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        let events = engine.transcribe(input)
        let feeder = Task {
            var i = 0
            while i < samples.count {
                let end = min(i + chunkSize, samples.count)
                feed.yield(AudioChunk(samples: Array(samples[i..<end]), format: spec))
                i = end
            }
            feed.finish()
        }

        let collector = Task {
            var assembler = TranscriptAssembler()
            for try await event in events { _ = assembler.apply(event) }
            return assembler.committedText
        }
        await feeder.value
        try await engine.finish()
        let text = try await collector.value
        print("TRANSCRIBED: \"\(text)\"")
        let lowered = text.lowercased()
        #expect(lowered.contains("hello"))
        #expect(lowered.contains("dictation"))
    }
}
